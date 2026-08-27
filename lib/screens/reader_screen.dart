import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:page_turn_animation/page_turn_animation.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/book_library.dart';
import '../services/book_parser.dart';
import '../services/bookmarks.dart';
import '../services/pagination.dart';
import '../services/reading_stats.dart';
import '../theme/app_colors.dart';
import '../theme/reading_themes.dart';
import '../widgets/reader_settings_sheet.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  List<Chapter> _chapters = [];
  List<int> _chapterStarts = [];
  bool _loading = true;
  String? _error;

  // 阅读设置
  double _fontSize = 18;
  double _lineHeight = 1.7;
  int _themeIndex = 7;
  String _fontFamily = 'default';
  bool _volumePageTurn = false;
  double _brightness = 1.0; // 1.0 = 不降暗，应用内遮罩
  int _prevThemeIndex = 0; // 非夜间主题，供 🌙 切换回
  PageTurnMode _pageTurnMode = PageTurnMode.scroll;

  // 滚动与进度
  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();
  int _currentIndex = 0;
  Timer? _saveTimer;

  // 翻页模式（非滚动）
  final PageController _pageController = PageController();
  List<int> _pageStarts = [];
  List<int> _pageChars = []; // 每页起点的块内字符偏移（超长段落跨页切割）
  String _pagesCacheKey = '';
  int _pageIndex = 0; // 当前页（翻页模式下与 _currentIndex 互相映射）
  Timer? _pagesDebounce;
  bool _pagesComputing = false;
  int? _restoreBlockTarget; // 分页未就绪时暂存的跳转目标

  // 覆盖/仿真翻页动画
  late final AnimationController _pageAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addStatusListener(_onPageAnimStatus);
  int _pageFrom = 0;
  int _pageTo = 0;
  bool _pageAnimating = false;
  bool _turning = false;
  ui.Image? _simImage;
  final GlobalKey _pageRepaintKey = GlobalKey();

  bool _overlayVisible = false;

  // 书签
  List<Bookmark> _bookmarks = [];

  // 自动阅读
  bool _autoScrolling = false;
  int _autoSpeedMs = 1000; // 每段（块）滚动时长
  String _autoSpeedLabel = '中';
  Timer? _autoTimer;
  int _autoTarget = 0;

  // 阅读统计
  final BookLibrary _library = BookLibrary();
  final Stopwatch _readStopwatch = Stopwatch();
  int _flushedSeconds = 0;
  Timer? _flushTimer;

  static const MethodChannel _volumeChannel =
      MethodChannel('novel_reader/volume_keys');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _volumeChannel.setMethodCallHandler(_onVolumeKey);
    _init();
  }

  Future<void> _init() async {
    // 首先检查文件路径
    final book = widget.book;
    if (book.filePath.isEmpty) {
      if (!mounted) return;
      setState(() {
        _error = '文件路径为空，无法打开书籍';
        _loading = false;
      });
      return;
    }

    // 检查文件是否存在
    final file = File(book.filePath);
    if (!file.existsSync()) {
      if (!mounted) return;
      setState(() {
        _error = '书籍文件不存在：${book.filePath}\n\n可能已被删除或移动，请重新导入';
        _loading = false;
      });
      return;
    }

    await _loadSettings();
    _applySystemUI();
    final sp = await SharedPreferences.getInstance();
    final savedIndex = sp.getInt(_progressKey) ?? 0;
    final bookmarks = await BookmarkStore.load(widget.book.id);
    if (!mounted) return;
    setState(() => _bookmarks = bookmarks);
    _setVolumeKeysEnabled(_volumePageTurn);

    try {
      final filePath = widget.book.filePath;
      final formatName = widget.book.format.name;
      final bytes = await File(filePath).readAsBytes();
      final sw = Stopwatch()..start();
      final parsed = await compute(parseBookMessage, (bytes, formatName));
      debugPrint('解析完成 ${parsed.chapters.length} 章 '
          '字数=${parsed.wordCount} 耗时=${sw.elapsedMilliseconds}ms');
      if (!mounted) return;
      setState(() {
        _chapters = parsed.chapters;
        _chapterStarts = _computeStarts(_chapters);
        _loading = false;
      });
      _positionsListener.itemPositions.addListener(_onPositions);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_totalBlocks() == 0) return;
        _goToBlock(savedIndex);
      });
      _startReading(parsed);
    } catch (e, st) {
      debugPrint('打开书籍失败: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = '打开失败：$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushTimer?.cancel();
    _saveTimer?.cancel();
    _autoTimer?.cancel();
    _pagesDebounce?.cancel();
    _positionsListener.itemPositions.removeListener(_onPositions);
    _flushReadTime();
    _saveProgress();
    _setVolumeKeysEnabled(false);
    _pageController.dispose();
    _pageAnim.dispose();
    _simImage?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _readStopwatch.stop();
      _pauseAutoScroll();
    } else if (state == AppLifecycleState.resumed) {
      _readStopwatch.start();
      _applySystemUI();
    }
  }

  String get _progressKey => 'progress_${widget.book.id}';

  // ---- 设置持久化 ----
  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    final fontSize = sp.getDouble('font_size') ?? 18;
    final lineHeight = sp.getDouble('line_height') ?? 1.7;
    final themeIndex = sp.getInt('theme_index') ?? 7;
    final fontFamily = sp.getString('font_family') ?? 'default';
    final volumePageTurn = sp.getBool('volume_page_turn') ?? false;
    final brightness = sp.getDouble('brightness') ?? 1.0;
    final modeName = sp.getString('page_turn_mode') ?? 'scroll';
    final pageTurnMode = PageTurnMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => PageTurnMode.scroll,
    );
    if (!mounted) return;
    setState(() {
      _fontSize = fontSize;
      _lineHeight = lineHeight;
      _themeIndex = themeIndex;
      _fontFamily = fontFamily;
      _volumePageTurn = volumePageTurn;
      _brightness = brightness;
      _pageTurnMode = pageTurnMode;
    });
  }

  Future<void> _saveSettings() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('font_size', _fontSize);
    await sp.setDouble('line_height', _lineHeight);
    await sp.setInt('theme_index', _themeIndex);
    await sp.setString('font_family', _fontFamily);
    await sp.setBool('volume_page_turn', _volumePageTurn);
    await sp.setDouble('brightness', _brightness);
    await sp.setString('page_turn_mode', _pageTurnMode.name);
  }

  // ---- 进度 ----
  void _onPositions() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final first = positions.first.index;
    if (first != _currentIndex) {
      _currentIndex = first;
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
    }
  }

  Future<void> _saveProgress() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_progressKey, _currentIndex);
    final total = _totalBlocks();
    final ratio = total <= 1 ? 0.0 : _currentIndex / (total - 1);
    await sp.setDouble('${_progressKey}_ratio', ratio.clamp(0.0, 1.0));
    // 记录当前章节名，供书架「继续阅读」显示「第X章·章名」。
    if (_chapters.isNotEmpty) {
      final idx = _currentIndex.clamp(0, total - 1);
      final (chapter, _) = _locate(idx);
      final title = _chapters[chapter].title;
      await sp.setString(
        '${_progressKey}_chapter',
        title.isEmpty ? '第 ${chapter + 1} 章' : title,
      );
    }
  }

  // ---- 阅读统计 ----
  void _startReading(ParsedBook parsed) {
    _readStopwatch.start();
    _flushTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _flushReadTime());
    final now = DateTime.now().millisecondsSinceEpoch;
    final needWordCount = widget.book.wordCount == 0 && parsed.wordCount > 0;
    _library.updateBook(
      widget.book.id,
      setLastReadAt: now,
      setWordCount: needWordCount ? parsed.wordCount : null,
    );
  }

  Future<void> _flushReadTime() async {
    final elapsed = _readStopwatch.elapsed.inSeconds;
    final delta = elapsed - _flushedSeconds;
    if (delta <= 0) return;
    _flushedSeconds = elapsed;
    await _library.updateBook(widget.book.id, addReadSeconds: delta);
    await ReadingStats.addTotalSeconds(delta);
  }

  // ---- 章节/区块索引映射 ----
  List<int> _computeStarts(List<Chapter> chapters) {
    final starts = <int>[];
    var acc = 0;
    for (final c in chapters) {
      starts.add(acc);
      acc += c.paragraphs.length + 1; // +1 为章节标题块
    }
    return starts;
  }

  int _totalBlocks() {
    if (_chapters.isEmpty) return 0;
    final last = _chapters.last;
    return _chapterStarts.last + last.paragraphs.length + 1;
  }

  /// 区块下标 → (章节下标, 段落下标)，段落下标 -1 表示章节标题。
  (int, int) _locate(int index) {
    var lo = 0;
    var hi = _chapterStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_chapterStarts[mid] <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final chapter = lo;
    final offset = index - _chapterStarts[chapter];
    return (chapter, offset - 1);
  }

  // ---- 交互 ----
  void _toggleOverlay() {
    if (_autoScrolling) _pauseAutoScroll();
    setState(() => _overlayVisible = !_overlayVisible);
  }

  Future<void> _openSettings() async {
    final result = await showModalBottomSheet<ReaderSettings>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReaderSettingsSheet(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        themeIndex: _themeIndex,
        fontFamily: _fontFamily,
        volumePageTurn: _volumePageTurn,
        brightness: _brightness,
        pageTurnMode: _pageTurnMode,
        onChanged: _applySettings,
      ),
    );
    if (result == null) return;
    _applySettings(result);
    await _saveSettings();
    // 字号/翻页方式变化后，把当前段落保持在视野顶部（分页模式下跳到所在页）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_totalBlocks() == 0) return;
      _goToBlock(_currentIndex);
    });
  }

  /// 实时应用阅读设置（拖动滑块即时生效）；主题变化时同步系统栏图标色。
  void _applySettings(ReaderSettings s) {
    final themeChanged = s.themeIndex != _themeIndex;
    final volumeChanged = s.volumePageTurn != _volumePageTurn;
    setState(() {
      _fontSize = s.fontSize;
      _lineHeight = s.lineHeight;
      _themeIndex = s.themeIndex;
      _fontFamily = s.fontFamily;
      _volumePageTurn = s.volumePageTurn;
      _brightness = s.brightness;
      _pageTurnMode = s.pageTurnMode;
    });
    if (s.themeIndex != 7) _prevThemeIndex = s.themeIndex;
    if (themeChanged) _applySystemUI();
    if (volumeChanged) _setVolumeKeysEnabled(s.volumePageTurn);
  }

  /// 进入沉浸式全屏，并按当前主题设置状态栏/导航栏图标颜色。
  void _applySystemUI() {
    final theme = readingThemes[_themeIndex];
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(
      theme.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    );
  }

  Future<void> _openChapterList() async {
    final (currentChapter, _) = _locate(_currentIndex.clamp(0, _totalBlocks() - 1));
    final theme = readingThemes[_themeIndex];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (ctx, controller) {
          final primary = Theme.of(ctx).colorScheme.primary;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '目录',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: theme.text,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: _chapters.length,
                  itemBuilder: (ctx, i) {
                    final selected = i == currentChapter;
                    final title = _chapters[i].title.isEmpty
                        ? '第 ${i + 1} 章'
                        : _chapters[i].title;
                    return ListTile(
                      dense: true,
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: selected ? primary : theme.text,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _goToBlock(_chapterStarts[i], animate: true);
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- 音量键翻页 ----
  Future<dynamic> _onVolumeKey(MethodCall call) async {
    switch (call.method) {
      case 'volumeUp':
        if (_pageTurnMode == PageTurnMode.scroll) {
          _pageBy(-_visibleBlocks());
        } else {
          _turnBy(-1);
        }
        break;
      case 'volumeDown':
        if (_pageTurnMode == PageTurnMode.scroll) {
          _pageBy(_visibleBlocks());
        } else {
          _turnBy(1);
        }
        break;
    }
    return null;
  }

  Future<void> _setVolumeKeysEnabled(bool enabled) async {
    try {
      await _volumeChannel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// 当前视口内可见的区块数量，作为「一页」的粒度。
  int _visibleBlocks() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return 20;
    var min = positions.first.index;
    var max = positions.first.index;
    for (final p in positions) {
      if (p.index < min) min = p.index;
      if (p.index > max) max = p.index;
    }
    final n = max - min + 1;
    return n > 2 ? n : 20;
  }

  void _pageBy(int delta) {
    final total = _totalBlocks();
    if (total <= 1 || _chapters.isEmpty) return;
    final target = (_currentIndex + delta).clamp(0, total - 1);
    _scrollController.scrollTo(
      index: target,
      duration: const Duration(milliseconds: 220),
    );
  }

  // ---- 翻页模式跳转 ----

  /// 统一跳转：scroll 模式滚到 block；翻页模式跳到所在页。
  void _goToBlock(int index, {bool animate = false}) {
    final total = _totalBlocks();
    if (total == 0) return;
    final idx = index.clamp(0, total - 1);
    if (_pageTurnMode == PageTurnMode.scroll) {
      if (animate) {
        _scrollController.scrollTo(
          index: idx,
          alignment: 0,
          duration: const Duration(milliseconds: 220),
        );
      } else {
        _scrollController.jumpTo(index: idx, alignment: 0);
      }
      return;
    }
    // 分页还没算好（后台 isolate 计算中）：先记住目标，算好后跳。
    if (!_pagesReady || _pagesComputing) {
      _restoreBlockTarget = idx;
      return;
    }
    final page = Pagination.pageOf(_pageStarts, idx);
    _currentIndex = idx;
    if (_pageTurnMode == PageTurnMode.slide) {
      _pageIndex = page;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(page);
      }
    } else {
      setState(() => _pageIndex = page);
    }
  }

  /// 翻页模式下翻一页（dir = 1 下一页 / -1 上一页）。
  Future<void> _turnBy(int dir) async {
    final pageCount = _pageStarts.isEmpty ? 0 : _pageStarts.length - 1;
    if (pageCount <= 1) return;
    if (_pageTurnMode == PageTurnMode.slide) {
      final target = (_pageIndex + dir).clamp(0, pageCount - 1);
      if (target != _pageIndex && _pageController.hasClients) {
        _pageController.animateToPage(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    await _startTurn(dir);
  }

  /// 覆盖/仿真：播放一次翻页动画（cover 新页滑入覆盖，simulation 源页卷曲）。
  Future<void> _startTurn(int dir) async {
    if (_pageAnimating || _turning) return;
    final pageCount = _pageStarts.isEmpty ? 0 : _pageStarts.length - 1;
    if (pageCount <= 1) return;
    final from = _pageIndex;
    final to = (from + dir).clamp(0, pageCount - 1);
    if (to == from) return;

    _turning = true;
    try {
      if (_pageTurnMode == PageTurnMode.simulation) {
        final boundary = _pageRepaintKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
        if (boundary == null) return;
        final ratio = MediaQuery.of(context).devicePixelRatio;
        ui.Image? img;
        try {
          img = await boundary.toImage(pixelRatio: ratio);
        } catch (_) {}
        if (!mounted) return;
        if (img == null) {
          _jumpToPage(to);
          return;
        }
        setState(() {
          _simImage = img;
          _pageFrom = from;
          _pageTo = to;
          _pageAnimating = true;
        });
        _pageAnim.forward(from: 0);
        return;
      }

      // cover
      setState(() {
        _pageFrom = from;
        _pageTo = to;
        _pageAnimating = true;
      });
      _pageAnim.forward(from: 0);
    } finally {
      _turning = false;
    }
  }

  /// 直接跳到某页（无动画），用于仿真捕获失败兜底。
  void _jumpToPage(int page) {
    setState(() => _pageIndex = page);
    _currentIndex = _pageStarts[page];
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
  }

  void _onPageAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    setState(() {
      _pageIndex = _pageTo;
      _pageAnimating = false;
      _simImage?.dispose();
      _simImage = null;
    });
    _currentIndex = _pageStarts[_pageTo];
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_pageAnimating || _turning) return;
    final v = details.primaryVelocity ?? 0;
    if (v < -100) {
      _startTurn(1);
    } else if (v > 100) {
      _startTurn(-1);
    }
  }

  void _onPageChanged(int page) {
    if (_pageStarts.isEmpty || page >= _pageStarts.length - 1) return;
    _pageIndex = page;
    _currentIndex = _pageStarts[page];
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
  }

  // ---- 夜间快捷切换 ----
  Future<void> _toggleNight() async {
    setState(() {
      if (_themeIndex == 7) {
        _themeIndex = _prevThemeIndex == 7 ? 0 : _prevThemeIndex;
      } else {
        _prevThemeIndex = _themeIndex;
        _themeIndex = 7;
      }
    });
    _applySystemUI();
    await _saveSettings();
  }

  // ---- 书签 ----
  Future<void> _toggleBookmark() async {
    if (_chapters.isEmpty) return;
    final total = _totalBlocks();
    final idx = _currentIndex.clamp(0, total - 1);
    final (chapter, para) = _locate(idx);
    final existing = _bookmarks.indexWhere((b) => b.chapterIndex == chapter);
    if (existing >= 0) {
      setState(() => _bookmarks.removeAt(existing));
      await BookmarkStore.save(widget.book.id, _bookmarks);
      _toast('已删除书签');
      return;
    }
    final ch = _chapters[chapter];
    final title = ch.title.isEmpty ? '第 ${chapter + 1} 章' : ch.title;
    var snippet = '';
    if (para >= 0 && para < ch.paragraphs.length) {
      snippet = ch.paragraphs[para].replaceAll(RegExp(r'\s'), '');
      if (snippet.length > 40) snippet = snippet.substring(0, 40);
    }
    setState(() => _bookmarks.add(Bookmark(
          blockIndex: idx,
          chapterIndex: chapter,
          chapterTitle: title,
          snippet: snippet,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        )));
    await BookmarkStore.save(widget.book.id, _bookmarks);
    _toast('已添加书签');
  }

  Future<void> _openBookmarks() async {
    final theme = readingThemes[_themeIndex];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.35,
        builder: (ctx, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '书签',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.text,
                ),
              ),
            ),
            Expanded(
              child: _bookmarks.isEmpty
                  ? Center(
                      child: Text(
                        '还没有书签，点击顶栏 ⚑ 添加',
                        style: TextStyle(
                          color: theme.secondaryText,
                          fontSize: 14,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: _bookmarks.length,
                      itemBuilder: (ctx, i) {
                        final b = _bookmarks[i];
                        return ListTile(
                          title: Text(
                            b.chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: theme.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            b.snippet.isEmpty
                                ? _fmtTime(b.createdAt)
                                : b.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.secondaryText,
                            ),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline,
                                color: theme.secondaryText),
                            onPressed: () async {
                              setState(() => _bookmarks.removeAt(i));
                              await BookmarkStore.save(
                                  widget.book.id, _bookmarks);
                            },
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _goToBlock(b.blockIndex, animate: true);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 自动阅读 ----
  void _startAutoScroll(int speedMs, String label) {
    _autoTimer?.cancel();
    _autoSpeedMs = speedMs;
    _autoTarget = _currentIndex + 1;
    setState(() {
      _autoScrolling = true;
      _autoSpeedLabel = label;
      _overlayVisible = false;
    });
    _autoStep();
  }

  void _pauseAutoScroll() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (mounted && _autoScrolling) {
      setState(() => _autoScrolling = false);
    }
  }

  /// 逐段平滑滚动：每段用 linear 动画滚到下一块，动画结束后继续下一段，
  /// 形成连续的下滑，而不是突然跳一段。
  Future<void> _autoStep() async {
    if (!_autoScrolling || !mounted) return;

    if (_pageTurnMode == PageTurnMode.scroll) {
      final total = _totalBlocks();
      if (_autoTarget >= total) {
        _pauseAutoScroll();
        return;
      }
      try {
        await _scrollController.scrollTo(
          index: _autoTarget,
          alignment: 0,
          duration: Duration(milliseconds: _autoSpeedMs),
          curve: Curves.linear,
        );
      } catch (_) {
        // 单次滚动失败时仍推进目标，避免卡死。
      }
      if (!_autoScrolling || !mounted) return;
      _autoTarget++;
      _autoStep();
      return;
    }

    // 翻页模式：每隔 _autoSpeedMs 翻一页。
    final pageCount = _pageStarts.isEmpty ? 0 : _pageStarts.length - 1;
    if (pageCount <= 1) {
      _pauseAutoScroll();
      return;
    }
    await Future.delayed(Duration(milliseconds: _autoSpeedMs));
    if (!_autoScrolling || !mounted) return;
    if (_pageAnimating || _turning) {
      _autoStep();
      return;
    }
    if (_pageIndex >= pageCount - 1) {
      _pauseAutoScroll();
      return;
    }
    await _turnBy(1);
    if (_autoScrolling && mounted) _autoStep();
  }

  Future<void> _showAutoSpeedSheet() async {
    final theme = readingThemes[_themeIndex];
    const speeds = [
      ('慢', '较慢', 1600),
      ('中', '适中', 900),
      ('快', '较快', 450),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '自动阅读',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.text,
                ),
              ),
            ),
            for (final (label, desc, ms) in speeds)
              ListTile(
                title: Text(
                  '$label · $desc',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: (_autoScrolling && _autoSpeedMs == ms)
                        ? AppColors.accentLight
                        : theme.text,
                    fontWeight: (_autoScrolling && _autoSpeedMs == ms)
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _startAutoScroll(ms, label);
                },
              ),
            if (_autoScrolling)
              ListTile(
                title: Text(
                  '停止自动阅读',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: theme.secondaryText,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _pauseAutoScroll();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---- 小工具 ----
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.month}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final theme = readingThemes[_themeIndex];
    if (_loading) {
      return Scaffold(
        backgroundColor: theme.background,
        body: Center(
          child: CircularProgressIndicator(color: theme.text),
        ),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: theme.background,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 56, color: theme.secondaryText),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.text, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return _buildReader(theme);
  }

  Widget _buildReader(ReadingTheme theme) {
    final pageMode = _pageTurnMode != PageTurnMode.scroll;
    Widget content;
    if (pageMode) {
      _ensurePages();
      // 分页在后台计算，未就绪前显示进度圈而不是冻结的页面。
      content = _pagesReady && !_pagesComputing
          ? _buildPaged(theme)
          : Center(child: CircularProgressIndicator(color: theme.text));
    } else {
      content = ScrollablePositionedList.builder(
        itemScrollController: _scrollController,
        itemPositionsListener: _positionsListener,
        itemCount: _totalBlocks(),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 24,
          bottom: MediaQuery.of(context).padding.bottom + 64,
        ),
        itemBuilder: (context, index) => _buildBlock(index, theme),
      );
    }
    return Scaffold(
      backgroundColor: theme.background,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleOverlay,
        onHorizontalDragEnd: pageMode && _pageTurnMode != PageTurnMode.slide
            ? _onHorizontalDragEnd
            : null,
        child: Stack(
          children: [
            content,
            if (_overlayVisible) _buildTopBar(theme),
            if (_overlayVisible) _buildBottomBar(theme),
            if (_autoScrolling) _buildAutoPill(theme),
            // 亮度遮罩：应用内降暗，盖在正文 + overlay 之上，点击穿透。
            if (_brightness < 1.0)
              IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: (1 - _brightness) * 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 当前排版/尺寸对应的分页缓存键。
  String _currentPagesKey() {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    return '$_fontSize|$_lineHeight|$_fontFamily|'
        '${size.width}|${size.height}|${padding.top}|${padding.bottom}';
  }

  bool get _pagesReady =>
      _pageStarts.isNotEmpty && _pagesCacheKey == _currentPagesKey();

  /// 翻页模式下确保分页结果可用。全书 TextPainter 测量不能在主线程
  /// 直接做（636 万字必卡帧触发 ANR），由 paginateAsync 决定去处；
  /// 设置连续变化只对最终值计算（300ms 防抖）。
  void _ensurePages() {
    if (_chapters.isEmpty || _pagesComputing || _pagesReady) return;
    final key = _currentPagesKey();
    _pagesDebounce?.cancel();
    _pagesDebounce =
        Timer(const Duration(milliseconds: 300), () => _computePages(key));
  }

  Future<void> _computePages(String key) async {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    _pagesComputing = true;
    if (mounted) setState(() {});
    try {
      final result = await paginateAsync(PaginationArgs(
        chapters: _chapters,
        chapterStarts: _chapterStarts,
        totalBlocks: _totalBlocks(),
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        fontFamily: _fontFamily,
        width: size.width,
        height: size.height - padding.top - padding.bottom - 24 - 64,
      ));
      debugPrint('分页完成 页数=${result.starts.length - 1}');
      if (!mounted) return;
      // 计算期间排版参数又变了：丢弃旧结果，下次 build 会重新调度。
      if (_currentPagesKey() != key) return;
      setState(() {
        _pageStarts = result.starts;
        _pageChars = result.chars;
        _pagesCacheKey = key;
        if (_pageIndex >= result.starts.length - 1) _pageIndex = 0;
      });
      final target = _restoreBlockTarget;
      _restoreBlockTarget = null;
      if (target != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _goToBlock(target));
      }
    } catch (e, st) {
      debugPrint('分页失败: $e\n$st');
    } finally {
      _pagesComputing = false;
      if (mounted) setState(() {});
    }
  }

  /// 非 scroll 模式的内容渲染（平移 PageView / 覆盖 / 仿真单页 + 动画覆盖层）。
  Widget _buildPaged(ReadingTheme theme) {
    final pageCount = _pageStarts.isEmpty ? 0 : _pageStarts.length - 1;
    if (pageCount == 0) return const SizedBox.shrink();

    if (_pageTurnMode == PageTurnMode.slide) {
      return PageView.builder(
        controller: _pageController,
        itemCount: pageCount,
        onPageChanged: _onPageChanged,
        itemBuilder: (c, i) => _buildPageContent(i, theme),
      );
    }

    Widget base;
    if (_pageAnimating && _pageTurnMode == PageTurnMode.simulation &&
        _simImage != null) {
      base = _colored(_buildPageContent(_pageTo, theme), theme);
    } else if (_pageAnimating && _pageTurnMode == PageTurnMode.cover) {
      base = _colored(_buildPageContent(_pageFrom, theme), theme);
    } else {
      base = RepaintBoundary(
        key: _pageRepaintKey,
        child: _colored(_buildPageContent(_pageIndex, theme), theme),
      );
    }

    final overlays = <Widget>[];
    if (_pageAnimating && _pageTurnMode == PageTurnMode.cover) {
      overlays.add(SlideTransition(
        position: Tween<Offset>(
          begin: Offset(_pageTo > _pageFrom ? 1 : -1, 0),
          end: Offset.zero,
        ).animate(_pageAnim),
        child: _colored(_buildPageContent(_pageTo, theme), theme),
      ));
    }
    if (_pageAnimating && _pageTurnMode == PageTurnMode.simulation &&
        _simImage != null) {
      overlays.add(PageTurnAnimation(
        image: _simImage!,
        animation: _pageAnim,
        direction: PageTurnDirection.forward,
        edge: _pageTo > _pageFrom ? PageTurnEdge.right : PageTurnEdge.left,
        style: PageTurnStyle(
          backgroundColor: theme.background,
          segments: 60,
        ),
      ));
    }

    return Stack(
      fit: StackFit.expand,
      children: [base, ...overlays],
    );
  }

  Widget _colored(Widget child, ReadingTheme theme) =>
      Container(color: theme.background, child: child);

  /// 第 [page] 页内容。页边界是游标 (块下标, 块内字符偏移)：
  /// 普通段落整块渲染；被分页器切开的超长段落按字符偏移切片，
  /// 跨越多页，只有每片开头带段首缩进。
  Widget _buildPageContent(int page, ReadingTheme theme) {
    var bi = _pageStarts[page];
    var cur = page < _pageChars.length ? _pageChars[page] : 0;
    final endB = _pageStarts[page + 1];
    final endC = page + 1 < _pageChars.length ? _pageChars[page + 1] : 0;
    final total = _totalBlocks();

    final blocks = <Widget>[];
    while ((bi < endB || (bi == endB && cur < endC)) && bi < total) {
      final (chapter, para) = _locate(bi);
      final chapterObj = _chapters[chapter];

      if (para < 0) {
        if (chapterObj.title.isNotEmpty) {
          blocks.add(_buildTitle(chapterObj.title, theme));
        }
        bi++;
        cur = 0;
        continue;
      }

      final txt = chapterObj.paragraphs[para];
      final isEndBlock = bi == endB;
      var segEnd = !isEndBlock || endC == 0
          ? txt.length
          : endC.clamp(cur, txt.length);
      if (segEnd <= cur) {
        // 游标异常兜底：跳过该块避免死循环。
        bi++;
        cur = 0;
        continue;
      }
      blocks.add(_buildBody(
        '${cur == 0 ? '　　' : ''}${txt.substring(cur, segEnd)}',
        theme,
      ));
      cur = segEnd;
      if (cur >= txt.length) {
        bi++;
        cur = 0;
      }
    }

    final padding = MediaQuery.of(context).padding;
    return Padding(
      padding: EdgeInsets.only(
        top: padding.top + 24,
        bottom: padding.bottom + 64,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: blocks,
      ),
    );
  }

  Widget _buildBlock(int index, ReadingTheme theme) {
    final (chapter, para) = _locate(index);
    final chapterObj = _chapters[chapter];

    if (para < 0) {
      if (chapterObj.title.isEmpty) return const SizedBox.shrink();
      return _buildTitle(chapterObj.title, theme);
    }

    // 段首空两格（两个全角空格），让段落分隔更明显。
    return _buildBody('　　${chapterObj.paragraphs[para]}', theme);
  }

  Widget _buildTitle(String title, ReadingTheme theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: _fontSize + 5,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: theme.text,
          fontFamily: _fontFamily == 'default' ? null : _fontFamily,
        ),
      ),
    );
  }

  /// [text] 为带缩进的最终渲染文本（滚动模式整段、翻页模式可能是切片）。
  Widget _buildBody(String text, ReadingTheme theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Text(
        text,
        textAlign: TextAlign.justify,
        style: TextStyle(
          fontSize: _fontSize,
          height: _lineHeight,
          color: theme.text,
          fontFamily: _fontFamily == 'default' ? null : _fontFamily,
        ),
      ),
    );
  }

  Widget _buildTopBar(ReadingTheme theme) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: theme.background,
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 4,
          bottom: 6,
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, color: theme.text),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                widget.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                _themeIndex == 7 ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
                color: theme.text,
              ),
              tooltip: '夜间切换',
              onPressed: _toggleNight,
            ),
            IconButton(
              icon: Icon(Icons.bookmark_add_outlined, color: theme.text),
              tooltip: '书签',
              onPressed: _toggleBookmark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ReadingTheme theme) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: theme.background,
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 4,
          top: 4,
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.menu_book_outlined, color: theme.text),
              tooltip: '目录',
              onPressed: _openChapterList,
            ),
            IconButton(
              icon: Icon(Icons.bookmarks_outlined, color: theme.text),
              tooltip: '书签列表',
              onPressed: _openBookmarks,
            ),
            Expanded(child: _buildProgress(theme)),
            IconButton(
              icon: Icon(
                _autoScrolling
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: theme.text,
              ),
              tooltip: '自动阅读',
              onPressed: _autoScrolling ? _pauseAutoScroll : _showAutoSpeedSheet,
            ),
            IconButton(
              icon: Icon(Icons.format_size, color: theme.text),
              tooltip: '设置',
              onPressed: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  /// 自动阅读进行时的悬浮胶囊（独立于 overlay，始终显示）。
  Widget _buildAutoPill(ReadingTheme theme) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _pauseAutoScroll,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.background.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_outline,
                    size: 16, color: AppColors.accentLight),
                const SizedBox(width: 6),
                Text(
                  '自动阅读 · ${_autoSpeedLabel}速（点击暂停）',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress(ReadingTheme theme) {
    final totalBlocks = _totalBlocks();
    final idx = _currentIndex.clamp(0, totalBlocks - 1);
    final (chapter, _) = _locate(idx);
    final total = _chapters.length;
    final ratio = totalBlocks <= 1 ? 0.0 : idx / (totalBlocks - 1);
    final percent = (ratio * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${chapter + 1} / $total 章 · $percent%',
          style: TextStyle(color: theme.secondaryText, fontSize: 12),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: theme.secondaryText.withValues(alpha: 0.4),
            color: AppColors.accent,
          ),
        ),
      ],
    );
  }
}
