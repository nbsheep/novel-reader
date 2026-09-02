import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../services/book_library.dart';
import '../services/guishuji_source.dart';
import '../theme/app_colors.dart';
import 'reader_screen.dart';

/// 站内搜索：内嵌 WebView 打开鬼书集（真实浏览器环境可过 Cloudflare）。
///
/// 顶部提供原生搜索框（网站搜索是 POST 表单，注入 JS 自动填词提交），
/// 并注入去广告脚本（删 iframe / 外链广告块 / 全屏悬浮层，MutationObserver
/// 持续拦截动态注入的广告）；第三方域名跳转在导航层直接拦掉。
/// 一旦进入某本书的目录页/章节页（/分类/id/），底部浮出「下载这本书」。
class WebSearchScreen extends StatefulWidget {
  const WebSearchScreen({super.key});

  @override
  State<WebSearchScreen> createState() => _WebSearchScreenState();
}

class _WebSearchScreenState extends State<WebSearchScreen> {
  late final WebViewController _webController;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _sweepTimer; // 定时补注入去广告脚本（见 initState）
  double? _loadProgress; // null = 未在加载
  String? _catalogUrl; // 当前页命中书目录页时的标准目录地址
  bool _everMatched = false; // 出现过下载按钮后不再显示顶部提示
  String? _pendingSearch; // 首页加载完后自动提交的搜索词

  bool _downloading = false;
  bool _cancelled = false;
  String _status = '';
  double? _progress;

  /// 去广告脚本：每个文档注入一次（window 标志保证幂等）。
/// ① 删所有 iframe/ins 及 Google 广告容器（google-anno-sa / google-auto-placed
/// / aswift 等）；② 删外链/广告关键词 <a> 及只包着它的容器；③ 删悬浮层——
/// 全屏遮罩或视口底部带链接/图片的宽条。
/// 关键坑：Google 锚定广告的宿主 DIV 挂在 <html> 下（body 之外），
/// 所以必须扫 documentElement 而不是 body。
/// MutationObserver 盯住动态插入，广告加载出来 150ms 内被清掉。
  static const String _adBlockJs = '''
(function(){
  if (window.__nzAdClean) return;
  window.__nzAdClean = true;
  var AD_WORDS = ['精品电子书', '法律服务', '红包', '抽奖', '领现金'];
  function sweep(){
    try {
      var ifs = document.querySelectorAll('iframe,ins,#google-anno-sa,[class*="google-anno"],.google-auto-placed,div[id^="aswift"],div[id^="google_ads"]');
      for (var i = 0; i < ifs.length; i++) ifs[i].remove();
      try { document.body.style.paddingBottom = ''; } catch(e){}
      var all = Array.prototype.slice.call(document.documentElement.getElementsByTagName('*'));
      for (var i = 0; i < all.length; i++) {
        if (all[i].shadowRoot) {
          var s2 = all[i].shadowRoot.querySelectorAll('iframe,ins');
          for (var j = 0; j < s2.length; j++) s2[j].remove();
        }
      }
      document.querySelectorAll('a[href]').forEach(function(a){
        var bad = false;
        try {
          var u = new URL(a.href, location.href);
          bad = (u.protocol === 'http:' || u.protocol === 'https:') &&
                u.host.indexOf('guishuji.com') < 0;
          if (!bad) {
            var txt = (a.innerText || '').trim();
            for (var i = 0; i < AD_WORDS.length; i++)
              if (txt.indexOf(AD_WORDS[i]) >= 0) { bad = true; break; }
          }
        } catch(e){}
        if (!bad) return;
        var node = a;
        for (var i = 0; i < 6; i++){
          var p = node.parentElement;
          if (!p || p === document.body || p === document.documentElement) break;
          if (p.children.length <= 3 && (p.innerText || '').trim().length < 80) node = p; else break;
        }
        // 站点自身 UI（搜索表单等）不可删
        try { if (node.querySelector('form,input,textarea,button,select')) return; } catch(e){}
        node.remove();
      });
      var vw = window.innerWidth, vh = window.innerHeight;
      var els = Array.prototype.slice.call(document.documentElement.getElementsByTagName('*'));
      for (var i = 0; i < els.length; i++){
        var d = els[i], s;
        try { s = getComputedStyle(d); } catch(e){ continue; }
        var pos = s.position;
        if (pos !== 'fixed' && pos !== 'sticky' && pos !== 'absolute') continue;
        var r = d.getBoundingClientRect();
        // 隐形元素不删（可能只是站点隐藏的搜索栏等 UI，删了会坏功能）
        if (r.width < 10 || r.height < 10) continue;
        var ui = false;
        try {
          ui = (d.matches && d.matches('form,input,textarea,button,select')) ||
               !!d.querySelector('form,input,textarea,button,select');
        } catch(e){}
        if (ui) continue;
        if (r.width > vw * 0.5 && r.height > vh * 0.5) { d.remove(); continue; }
        if (pos === 'absolute' && r.top < vh * 0.35) continue;
        if (r.width > vw * 0.5 && d.querySelector('a[href],iframe,ins,img')) d.remove();
      }
    } catch (e) {}
  }
  sweep();
  // 广告容器常先空壳插入、内容异步填充（图片加载不触发 childList 变动，
  // MutationObserver 感知不到），必须定时补扫才能及时清掉。
  var delays = [500, 1500, 3000, 6000, 10000, 15000, 22000, 30000, 45000, 60000];
  for (var i = 0; i < delays.length; i++) setTimeout(sweep, delays[i]);
  var t = null;
  new MutationObserver(function(){
    if (t) return;
    t = setTimeout(function(){ t = null; sweep(); }, 150);
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
''';

  @override
  void initState() {
    super.initState();
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _loadProgress = p >= 100 ? null : p / 100);
        },
        onNavigationRequest: (req) {
          final Uri uri = Uri.tryParse(req.url) ?? Uri();
          final host = uri.host.toLowerCase();
          if (host.isEmpty ||
              host == 'guishuji.com' ||
              host.endsWith('.guishuji.com')) {
            return NavigationDecision.navigate;
          }
          // 第三方跳转（广告落地页等）一律拦下，防止误点跳出网页。
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) async {
          await _injectAdBlock();
          _checkUrl();
        },
        onUrlChange: (_) => _checkUrl(),
      ))
      ..loadRequest(Uri.parse(GuishujiSource.base));
    // onPageFinished 在 Cloudflare 跳转链上会偶发丢失（实测整页加载完
    // 事件都没回调，去广告脚本注入不上），这里定时补注入兜底；
    // 脚本内 window.__nzAdClean 保证同一文档只生效一次，重复注入是空操作。
    _sweepTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        await _webController.runJavaScript(_adBlockJs);
      } catch (_) {}
      final kw = _pendingSearch;
      if (kw != null && await _trySubmitSearch(kw)) {
        _pendingSearch = null;
      }
    });
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _injectAdBlock() async {
    try {
      await _webController.runJavaScript(_adBlockJs);
    } catch (_) {}
  }

  /// 原生搜索框提交：网站搜索是 POST 表单（#schform/#keyboard）。
  /// 当前页已有表单就直接提交；否则记下待搜词并回首页，
  /// 由定时器在首页就绪后补提交（onPageFinished 在 CF 跳转链上不可靠）。
  Future<void> _doSearch() async {
    final kw = _searchCtrl.text.trim();
    if (kw.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (await _trySubmitSearch(kw)) return;
    if (!mounted) return;
    _pendingSearch = kw;
    _webController.loadRequest(Uri.parse(GuishujiSource.base));
  }

  String _submitSearchJs(String kw) => '''
(function(){
  var f = document.getElementById('schform');
  var k = document.getElementById('keyboard');
  if (!f || !k) return 'noform';
  k.value = ${jsonEncode(kw)};
  f.submit();
  return 'ok';
})()
''';

  /// 在当前文档里尝试提交搜索；表单存在并已提交返回 true。
  Future<bool> _trySubmitSearch(String kw) async {
    try {
      final r = await _webController
          .runJavaScriptReturningResult(_submitSearchJs(kw));
      return r.toString().replaceAll('"', '') == 'ok';
    } catch (_) {
      return false;
    }
  }

  /// 当前网页 URL 命中书目录页时，记下标准目录地址并浮出下载按钮。
  Future<void> _checkUrl() async {
    final url = await _webController.currentUrl();
    if (!mounted) return;
    final catalog = url == null ? null : GuishujiSource.resolveCatalogUrl(url);
    setState(() {
      _catalogUrl = catalog;
      if (catalog != null) _everMatched = true;
    });
  }

  Future<void> _download() async {
    final catalogUrl = _catalogUrl;
    if (catalogUrl == null || _downloading) return;

    CatalogInfo info;
    try {
      info = await GuishujiSource.fetchCatalogInfo(catalogUrl);
    } catch (e) {
      _toast('获取书籍信息失败：$e');
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载本书'),
        content: Text(
          '《${info.title}》\n\n'
          '作者：${info.author.isEmpty ? '未知' : info.author}\n'
          '预计 ${info.chapterCount} 章\n\n'
          '将下载为 EPUB 并加入书架。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _downloading = true;
      _cancelled = false;
      _status = '正在准备下载…';
      _progress = null;
    });

    try {
      final result = await GuishujiSource.downloadBook(
        catalogUrl,
        isCancelled: () => _cancelled,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _status = '正在抓取章节 $done / $total';
            _progress = done / total;
          });
        },
      );
      final book = await BookLibrary().addDownloadedBook(
        result.filePath,
        result.title,
        result.author,
        coverTempPath: result.coverFilePath,
        sourceCatalogUrl: catalogUrl,
        sourceLastChapterId: result.lastChapterId,
      );
      if (!mounted) return;
      setState(() => _downloading = false);
      _showDone(book, result.chapterCount);
    } on DownloadCancelled {
      if (mounted) {
        setState(() => _downloading = false);
        _toast('已取消下载');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloading = false);
        _toast('下载失败：$e');
      }
    }
  }

  void _showDone(Book book, int chapterCount) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载完成'),
        content: Text('《${book.title}》已加入书架（$chapterCount 章）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续逛'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
              );
            },
            child: const Text('立即阅读'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 下载中拦截返回键，避免误触退出中断任务（可点浮层里的取消）。
      canPop: !_downloading,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('站内搜索'),
          actions: [
            IconButton(
              icon: const Icon(Icons.home_outlined),
              tooltip: '回官网首页',
              onPressed: () =>
                  _webController.loadRequest(Uri.parse(GuishujiSource.base)),
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                _buildSearchBar(),
                if (_loadProgress != null)
                  LinearProgressIndicator(value: _loadProgress, minHeight: 2),
                if (!_everMatched)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 15, color: AppColors.accentLight),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '搜索后点进书的目录页，这里会出现下载按钮',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(child: WebViewWidget(controller: _webController)),
              ],
            ),
            if (_catalogUrl != null && !_downloading) _buildDownloadBar(),
            if (_downloading) _buildDownloadOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _doSearch(),
              style:
                  const TextStyle(fontSize: 15, color: AppColors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入书名搜索，如：将门毒后',
                hintStyle: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            onPressed: _doSearch,
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: _download,
            icon: const Icon(Icons.download_outlined),
            label: const Text('下载这本书'),
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      alignment: Alignment.center,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '正在下载',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                _status,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress, minHeight: 6),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() => _cancelled = true),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
