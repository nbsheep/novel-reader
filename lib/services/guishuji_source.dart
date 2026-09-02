import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'epub_builder.dart';

/// 分类拼音 → 中文名（用于在线找书的分类浏览）。
const Map<String, String> guishujiCategories = {
  'kehuan': '科幻',
  'wuxia': '武侠',
  'yanqing': '言情',
  'dushi': '都市',
  'kongbu': '恐怖',
  'lingyi': '灵异悬疑',
  'daomu': '盗墓',
  'daoshi': '道士',
  'wangluo': '网络',
  'gudian': '古典',
  'waiguo': '外国',
  'xiandai': '现代',
  'guoxue': '国学',
  'sanwen': '散文',
  'ys': '影视原著',
};

/// 分类页里的一本书（书名 / 作者 / 简介 / 封面）。
class BookItem {
  final String id;
  final String title;
  final String author;
  final String intro;
  final String coverUrl; // 相对路径，如 /d/file/kehuan/xxx.jpg
  final String category; // 分类拼音，如 kehuan

  const BookItem({
    required this.id,
    required this.title,
    required this.author,
    required this.intro,
    required this.coverUrl,
    required this.category,
  });

  String get coverFullUrl => '${GuishujiSource.base}$coverUrl';
  String get catalogUrl => '${GuishujiSource.base}/$category/$id/';
}

/// 目录页解析结果。
class CatalogInfo {
  final String title;
  final String author;
  final String category; // 分类拼音
  final int bookId;
  final int firstId; // 首章文章 ID
  final int lastId; // 末章文章 ID
  final String? coverUrl; // 封面绝对 URL（无封面为 null）

  const CatalogInfo({
    required this.title,
    required this.author,
    required this.category,
    required this.bookId,
    required this.firstId,
    required this.lastId,
    this.coverUrl,
  });

  int get chapterCount => lastId - firstId + 1;
}

/// 下载被用户取消。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// 下载结果。
class DownloadResult {
  final String filePath; // 临时 EPUB 文件路径
  final String title;
  final String author;
  final int chapterCount;
  final String? coverFilePath; // 临时封面图路径（抓取失败为 null）
  final int lastChapterId; // 末章文章 ID（检查更新用）

  const DownloadResult({
    required this.filePath,
    required this.title,
    required this.author,
    required this.chapterCount,
    this.coverFilePath,
    required this.lastChapterId,
  });
}

/// 鬼书集（m.guishuji.com）数据源：分类浏览 + 目录解析 + 章节抓取 + 整本下载。
///
/// 章节文章 ID 在 [firstId, lastId] 区间内连续（中间偶有 404 跳号），
/// 因此抓整本 = 遍历 ID 区间、404 跳过。
class GuishujiSource {
  static const String base = 'https://m.guishuji.com';
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  // 目录页
  static final _titleRe =
      RegExp(r'<h1 class="focusbox-title">(.*?)</h1>', dotAll: true);
  static final _authorRe = RegExp(r'作者：<a[^>]*>([^<]+)</a>');
  static final _sidRe = RegExp(r'data-sid="(\d+)"');
  static final _chapterLinkRe =
      RegExp(r'href="/([a-z]+)/(\d+)/(\d+)\.html"');
  static final _ogImageRe =
      RegExp(r'property="og:image"\s+content="([^"]+)"');
  static final _coverImgRe = RegExp(r'<img class="shadow-img" src="([^"]+)"');

  // 正文页
  static final _articleTitleRe =
      RegExp(r'<h1 class="article-title">(.*?)</h1>', dotAll: true);
  static final _contentRe =
      RegExp(r'<article class="article-content">(.*?)</article>', dotAll: true);
  static final _pRe = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true);
  static final _tagRe = RegExp(r'<[^>]+>');

  // ---- 分类浏览 ----

  /// 抓取某个分类的书列表（page 从 1 开始；第 1 页是 `/{cat}/`，之后是 `/{cat}/index_N.html`）。
  static Future<List<BookItem>> fetchCategoryBooks(
    String category, {
    int page = 1,
  }) async {
    final url = page <= 1
        ? '$base/$category/'
        : '$base/$category/index_$page.html';
    final html = await _get(url);
    if (html == null) throw const FormatException('分类页请求失败');
    return parseCategoryBooks(html, category);
  }

  /// 从分类页 HTML 解析书列表。
  static List<BookItem> parseCategoryBooks(String html, String category) {
    final items = <BookItem>[];
    final liRe = RegExp(r'<li>(.*?)</li>', dotAll: true);
    final coverRe = RegExp(
      r'<a href="/([a-z]+)/(\d+)/"[^>]*class="cover"[^>]*>\s*'
      r'<img src="([^"]+)" alt="([^"]*)"',
    );
    final titleRe =
        RegExp(r'<h2 class="title">\s*<a[^>]*>([^<]+)</a>', dotAll: true);
    final authorRe = RegExp(r'作者：<a[^>]*>([^<]+)</a>');
    final textRe = RegExp(r'<div class="text">(.*?)</div>', dotAll: true);

    for (final m in liRe.allMatches(html)) {
      final block = m.group(1)!;
      final cover = coverRe.firstMatch(block);
      if (cover == null) continue;
      final id = cover.group(2)!;
      final coverUrl = cover.group(3)!;
      var title = titleRe.firstMatch(block)?.group(1)?.trim() ?? '';
      if (title.isEmpty) title = cover.group(4)!.trim();
      final author = authorRe.firstMatch(block)?.group(1)?.trim() ?? '';
      final intro = _clean(textRe.firstMatch(block)?.group(1) ?? '');
      items.add(BookItem(
        id: id,
        title: title,
        author: author,
        intro: intro,
        coverUrl: coverUrl,
        category: category,
      ));
    }
    return items;
  }

  // ---- 目录解析 ----

  /// 从目录页 HTML 提取书籍信息。
  ///
  /// 章节链接形如 `/{分类}/{书id}/{章节id}.html`（前缀是分类拼音，不是固定的 /ys/），
  /// 因此先取 `data-sid` 定位书，再过滤出属于本书的章节链接，取 min/max 作为首末章。
  static CatalogInfo parseCatalog(String html) {
    final title = _titleRe.firstMatch(html)?.group(1)?.trim();
    final author = _authorRe.firstMatch(html)?.group(1)?.trim() ?? '';
    final sid = _sidRe.firstMatch(html)?.group(1);
    final bookId = int.tryParse(sid ?? '');

    if (title == null || title.isEmpty) {
      throw const FormatException('无法解析书名，可能不是书籍目录页');
    }
    if (bookId == null) {
      throw const FormatException('无法解析书籍 ID');
    }

    final matches = _chapterLinkRe
        .allMatches(html)
        .where((m) => m.group(2) == sid)
        .toList();
    if (matches.isEmpty) {
      throw const FormatException('无法解析章节列表');
    }
    final category = matches.first.group(1)!;
    final ids = matches.map((m) => int.parse(m.group(3)!)).toList();

    // 封面：优先 og:image（绝对地址），其次 shadow-img（相对地址）。
    final ogImage = _ogImageRe.firstMatch(html)?.group(1)?.trim();
    final coverRel = _coverImgRe.firstMatch(html)?.group(1)?.trim();
    String? coverUrl;
    if (ogImage != null && ogImage.isNotEmpty) {
      coverUrl = ogImage.startsWith('http') ? ogImage : '$base$ogImage';
    } else if (coverRel != null && coverRel.isNotEmpty) {
      coverUrl = coverRel.startsWith('http') ? coverRel : '$base$coverRel';
    }

    return CatalogInfo(
      title: title,
      author: author,
      category: category,
      bookId: bookId,
      firstId: ids.reduce(min),
      lastId: ids.reduce(max),
      coverUrl: coverUrl,
    );
  }

  /// 抓取单个章节，返回标题 + 正文段落；404/无正文返回 null。
  static Future<EpubChapter?> fetchChapter(
    String category,
    int bookId,
    int chid,
  ) async {
    final html = await _get('$base/$category/$bookId/$chid.html');
    if (html == null) return null;
    final title = _articleTitleRe.firstMatch(html)?.group(1)?.trim();
    if (title == null || title.isEmpty) return null;

    final content = _contentRe.firstMatch(html)?.group(1);
    if (content == null) return null;

    final paras = <String>[];
    for (final m in _pRe.allMatches(content)) {
      final line = _clean(m.group(1) ?? '');
      if (line.isEmpty) continue;
      if (line.startsWith('=') ||
          line.startsWith('本站') ||
          line.contains('pan.quark')) {
        continue;
      }
      if (line.contains('guishuji') || line.contains('鬼书集')) continue;
      paras.add(line);
    }
    if (paras.isEmpty) return null;
    return EpubChapter(title: title, paragraphs: paras);
  }

  /// 仅抓取目录页，返回书籍信息（下载前弹确认框用）。
  static Future<CatalogInfo> fetchCatalogInfo(String catalogUrl) async {
    final html = await _get(catalogUrl);
    if (html == null) throw const FormatException('目录页请求失败');
    return parseCatalog(html);
  }

  static final _bookPathRe = RegExp(r'/([a-z]+)/(\d+)/?');

  /// 从用户粘贴的目录页 / 章节页链接，解析出标准目录页地址；无法识别返回 null。
  ///
  /// 例：`https://m.guishuji.com/kehuan/12453/` 或 `.../kehuan/12453/1619780.html`
  /// 都返回 `https://m.guishuji.com/kehuan/12453/`。
  static String? resolveCatalogUrl(String input) {
    final m = _bookPathRe.firstMatch(input.trim());
    if (m == null) return null;
    return '$base/${m.group(1)}/${m.group(2)}/';
  }

  /// 并发抓取章节 ID 区间 [firstId, lastId]，返回抓到的章节（按 ID 升序，
  /// 404/失败项跳过）。[isCancelled] 返回 true 时抛 [DownloadCancelled]。
  static Future<List<EpubChapter>> _fetchRange(
    CatalogInfo info,
    int firstId,
    int lastId, {
    required void Function(int done, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final total = lastId - firstId + 1;
    if (total <= 0) return [];

    final results = <int, EpubChapter?>{};
    var cursor = 0;
    final rng = Random();

    Future<void> worker() async {
      while (cursor < total) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadCancelled();
        }
        final idx = cursor++;
        final chid = firstId + idx;
        var chapter = await fetchChapter(info.category, info.bookId, chid);
        // 失败重试一次
        if (chapter == null) {
          await Future.delayed(const Duration(milliseconds: 500));
          chapter = await fetchChapter(info.category, info.bookId, chid);
        }
        results[idx] = chapter;
        // 温和延迟，避免触发 429 限流。
        await Future.delayed(Duration(milliseconds: 180 + rng.nextInt(320)));
        onProgress(idx + 1, total);
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));

    final chapters = <EpubChapter>[];
    for (var i = 0; i < total; i++) {
      final c = results[i];
      if (c != null) chapters.add(c);
    }
    return chapters;
  }

  /// 增量抓取 [afterId] 之后（不含）到当前末章的新章节，升序返回。
  /// 已追平则返回空列表。
  static Future<List<EpubChapter>> fetchNewChapters(
    CatalogInfo info,
    int afterId, {
    required void Function(int done, int total) onProgress,
    bool Function()? isCancelled,
  }) =>
      _fetchRange(
        info,
        afterId + 1 > info.firstId ? afterId + 1 : info.firstId,
        info.lastId,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

  /// 下载整本书为 EPUB，返回临时文件路径。
  ///
  /// [isCancelled] 返回 true 时中断下载（抛 [DownloadCancelled]）。
  static Future<DownloadResult> downloadBook(
    String catalogUrl, {
    required void Function(int done, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final info = await fetchCatalogInfo(catalogUrl);

    final total = info.lastId - info.firstId + 1;
    if (total <= 0 || total > 100000) {
      throw const FormatException('章节区间异常');
    }

    final chapters = await _fetchRange(
      info,
      info.firstId,
      info.lastId,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    if (chapters.isEmpty) {
      throw const FormatException('未抓到任何章节内容');
    }

    final bytes = EpubBuilder.build(
      title: info.title,
      author: info.author,
      chapters: chapters,
    );

    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'download_${info.bookId}.epub'));
    await file.writeAsBytes(bytes, flush: true);

    // 顺带抓封面（失败不影响整本下载）。
    String? coverFilePath;
    final coverUrl = info.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      final coverBytes = await fetchImageBytes(coverUrl);
      if (coverBytes != null && coverBytes.isNotEmpty) {
        var ext = p.extension(Uri.parse(coverUrl).path).toLowerCase();
        if (ext.isEmpty) ext = '.jpg';
        final coverFile = File(p.join(dir.path, 'cover_${info.bookId}$ext'));
        await coverFile.writeAsBytes(coverBytes, flush: true);
        coverFilePath = coverFile.path;
      }
    }

    return DownloadResult(
      filePath: file.path,
      title: info.title,
      author: info.author,
      chapterCount: chapters.length,
      coverFilePath: coverFilePath,
      lastChapterId: info.lastId,
    );
  }

  /// 抓取图片原始字节；失败返回 null。
  static Future<Uint8List?> fetchImageBytes(String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _get(String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes;
      try {
        return utf8.decode(bytes);
      } catch (_) {
        try {
          return gbk.decode(bytes);
        } catch (_) {
          return utf8.decode(bytes, allowMalformed: true);
        }
      }
    } catch (_) {
      return null;
    }
  }

  static String _clean(String s) {
    var t = s.replaceAll(_tagRe, '');
    t = t
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&hellip;', '…')
        .replaceAll('&mdash;', '—')
        .replaceAll('&middot;', '·');
    return t.trim();
  }
}
