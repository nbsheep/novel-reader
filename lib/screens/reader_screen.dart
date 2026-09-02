import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:page_turn_animation/page_turn_animation.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/book.dart';
import '../services/book_library.dart';
import '../services/book_parser.dart';
import '../services/bookmarks.dart';
import '../services/custom_font.dart';
import '../services/pagination.dart';
import '../services/pagination_cache.dart';
import '../services/parse_cache.dart';
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
  bool _chapterListDesc = false; // 目录倒序（最新章在前）

  // 滚动与进度
  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();
  int _currentIndex = 0;
  int _listAnchor = 0; // 列表重建锚点：跳章/恢复进度用它精确落位
  Timer? _saveTimer;
  Timer? _settingsSaveTimer; // 设置实时改动防抖落盘

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

  // 书签
  List<Bookmark> _bookmarks = [];

  // 自动阅读
  bool _autoScrolling = false;
  int _autoSpeedMs = 1000; // 每段（块）滚动时长
  String _autoSpeedLabel = '中';
  Timer? _autoTimer;
  int _autoTarget = 0;

  // 听书 TTS
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false; // 引擎已初始化
  bool _ttsActive = false;
  int _ttsBlock = 0; // 当前朗读到的区块
  double _ttsSpeed = 1.0;
  int _ttsGen = 0; // 朗读代次：停止/重启后旧循环自行退出

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
    WakelockPlus.enable(); // 阅读时不锁屏
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
      final srcStat = await file.stat();
      final srcMtime = srcStat.modified.millisecondsSinceEpoch;
      final cachePath = await ParseCache.pathFor(widget.book.id);
      final sw = Stopwatch()..start();
      // 同一本书只真正解析一次：命中缓存直接反序列化，未命中才解析并落盘。
      ParsedBook? cached = await compute(
          ParseCache.load, (cachePath, filePath, srcStat.size, srcMtime));
      final fromCache = cached != null;
      final ParsedBook parsed;
      if (cached != null) {
        parsed = cached;
      } else {
        final bytes = await File(filePath).readAsBytes();
        parsed = await compute(parseBookMessage, (bytes, formatName));
        unawaited(compute(ParseCache.save, (
          cachePath,
          srcStat.size,
          srcMtime,
          parsed.chapters,
          parsed.wordCount
        )));
      }
      debugPrint('解析${fromCache ? '(缓存命中)' : ''}完成 ${parsed.chapters.length} 章 '
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
    if (_settingsSaveTimer != null) {
      // 最后一次改动后 400ms 内退出阅读页：冲刷一次保证不丢。
      _settingsSaveTimer!.cancel();
      unawaited(_saveSettings());
    }
    _autoTimer?.cancel();
    _pagesDebounce?.cancel();
    _positionsListener.itemPositions.removeListener(_onPositions);
    _flushReadTime();
    _saveProgress();
    _ttsGen++;
    unawaited(_tts.stop());
    WakelockPlus.disable();
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
    final chapterListDesc = sp.getBool('chapter_list_desc') ?? false;
    final ttsSpeed = sp.getDouble('tts_speed') ?? 1.0;
    // 自定义字体要在首次排版/分页前注册好，否则测量与渲染不一致。
    if (fontFamily == CustomFont.family) await CustomFont.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _fontSize = fontSize;
      _lineHeight = lineHeight;
      _themeIndex = themeIndex;
      _fontFamily = fontFamily;
      _volumePageTurn = volumePageTurn;
      _brightness = brightness;
      _pageTurnMode = pageTurnMode;
      _chapterListDesc = chapterListDesc;
      _ttsSpeed = ttsSpeed;
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
  /// 点按分区翻页/滚动：主流阅读器的操作方式。
  /// 翻页模式：左 1/3 上一页、右 1/3 下一页、中间呼出面板；
  /// 滚动模式：上 1/3 上滚一屏、下 1/3 下滚一屏、中间呼出面板。
  void _onTapUp(Offset pos) {
    final size = MediaQuery.of(context).size;
    if (_pageTurnMode == PageTurnMode.scroll) {
      final third = size.height / 3;
      if (pos.dy < third) {
        _pageBy(-_visibleBlocks());
      } else if (pos.dy > third * 2) {
        _pageBy(_visibleBlocks());
      } else {
        _toggleOverlay();
      }
      return;
    }
    final third = size.width / 3;
    if (pos.dx < third) {
      _turnBy(-1);
    } else if (pos.dx > third * 2) {
      _turnBy(1);
    } else {
      _toggleOverlay();
    }
  }

  /// 点屏幕中央呼出阅读面板（进度/目录/书签/设置一体）。
  void _toggleOverlay() {
    _openSettings();
  }

  Future<void> _openSettings() async {
    final total = _totalBlocks();
    if (total <= 0 || _chapters.isEmpty) return;
    final idx = _currentIndex.clamp(0, total - 1);
    final (chapter, _) = _locate(idx);
    final titles = List<String>.generate(_chapters.length, (i) {
      final t = _chapters[i].title;
      return t.isEmpty ? '第 ${i + 1} 章' : t;
    });
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => ReaderPanelSheet(
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        themeIndex: _themeIndex,
        fontFamily: _fontFamily,
        volumePageTurn: _volumePageTurn,
        brightness: _brightness,
        pageTurnMode: _pageTurnMode,
        onChanged: _applySettings,
        currentChapter: chapter,
        totalChapters: _chapters.length,
        chapterTitles: titles,
        progressRatio: total <= 1 ? 0 : idx / (total - 1),
        autoScrolling: _autoScrolling,
        bookmarked: _bookmarks.any((b) => b.chapterIndex == chapter),
        onToggleBookmark: _toggleBookmark,
        onSeekChapter: (i) => _goToBlock(_chapterStarts[i], animate: true),
        onOpenChapters: _openChapterList,
        onOpenBookmarks: _openBookmarks,
        onToggleAuto: () {
          if (_autoScrolling) {
            _pauseAutoScroll();
          } else {
            _showAutoSpeedSheet();
          }
        },
        onToggleTts: () {
          if (_ttsActive) {
            _ttsStop();
          } else {
            _showTtsSpeedSheet();
          }
        },
        onImportFont: _importCustomFont,
        lastLightTheme: _prevThemeIndex,
      ),
    );
    if (!mounted) return;
    if (result == 'exit') {
      Navigator.pop(context);
      return;
    }
    if (result is ReaderSettings) {
      _applySettings(result);
      await _saveSettings();
      // 字号/翻页方式变化后，把当前段落保持在视野顶部（分页模式下跳到所在页）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_totalBlocks() == 0) return;
        _goToBlock(_currentIndex);
      });
    }
  }

  /// 实时应用阅读设置（拖动滑块即时生效）；主题变化时同步系统栏图标色。
  void _applySettings(ReaderSettings s) {
    final themeChanged = s.themeIndex != _themeIndex;
    final volumeChanged = s.volumePageTurn != _volumePageTurn;
    // 从翻页模式切回滚动时，列表会按 _listAnchor 重新初始化；
    // 若不同步到当前进度，首帧从旧锚点渲染，_onPositions 会把
    // _currentIndex 覆写成旧位置导致跳回书首。
    final toScroll = s.pageTurnMode == PageTurnMode.scroll &&
        _pageTurnMode != PageTurnMode.scroll;
    setState(() {
      _fontSize = s.fontSize;
      _lineHeight = s.lineHeight;
      _themeIndex = s.themeIndex;
      _fontFamily = s.fontFamily;
      _volumePageTurn = s.volumePageTurn;
      _brightness = s.brightness;
      _pageTurnMode = s.pageTurnMode;
      if (toScroll) _listAnchor = _currentIndex;
    });
    if (s.themeIndex != 7) _prevThemeIndex = s.themeIndex;
    if (themeChanged) _applySystemUI();
    if (volumeChanged) _setVolumeKeysEnabled(s.volumePageTurn);
    // 面板可能被点外部/下拉/返回键关闭（pop 无值），只靠「确定」落盘
    // 会丢改动；改为实时改动防抖保存，任何关闭方式都已持久化。
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer =
        Timer(const Duration(milliseconds: 400), _saveSettings);
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
    final (currentChapter, _) =
        _locate(_currentIndex.clamp(0, _totalBlocks() - 1));
    final theme = readingThemes[_themeIndex];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ChapterListSheet(
        chapters: _chapters,
        currentChapter: currentChapter,
        theme: theme,
        descending: _chapterListDesc,
        onDescendingChanged: (v) async {
          setState(() => _chapterListDesc = v);
          final sp = await SharedPreferences.getInstance();
          await sp.setBool('chapter_list_desc', v);
        },
        onSelect: (i) {
          Navigator.pop(ctx);
          _goToBlock(_chapterStarts[i], animate: true);
        },
        onSearch: () {
          Navigator.pop(ctx);
          _openSearch();
        },
      ),
    );
  }

  Future<void> _openSearch() async {
    final theme = readingThemes[_themeIndex];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SearchSheet(
        chapters: _chapters,
        chapterStarts: _chapterStarts,
        theme: theme,
        onJump: (block) {
          Navigator.pop(ctx);
          _goToBlock(block, animate: true);
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
      if (idx != _listAnchor) {
        // scrollTo/jumpTo 大跨度落点按平均块高估计、误差可达一屏；
        // 换 key 重建列表用 initialScrollIndex 从目标块精确开始布局。
        setState(() {
          _listAnchor = idx;
          _currentIndex = idx;
        });
        _saveTimer?.cancel();
        _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
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

  // ---- 听书 TTS ----
  Future<bool> _initTts() async {
    if (_ttsReady) return true;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(_ttsSpeed);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ttsReady = true;
    } catch (_) {}
    return _ttsReady;
  }

  Future<void> _startTts() async {
    if (_ttsActive) return;
    final total = _totalBlocks();
    if (total == 0) return;
    if (!await _initTts()) {
      _toast('本机没有可用的中文语音引擎');
      return;
    }
    final gen = ++_ttsGen;
    if (!mounted) return;
    setState(() {
      _ttsActive = true;
      _ttsBlock = _currentIndex.clamp(0, total - 1);
    });
    await _ttsLoop(gen);
  }

  /// 逐块朗读：每块 speak 完（awaitSpeakCompletion）推进到下一块，
  /// 并让阅读视图跟随滚动/翻页。代次不匹配即退出。
  Future<void> _ttsLoop(int gen) async {
    final total = _totalBlocks();
    while (gen == _ttsGen && mounted && _ttsBlock < total) {
      final i = _ttsBlock;
      final (chapter, para) = _locate(i);
      final ch = _chapters[chapter];
      final text = (para < 0 ? ch.title : ch.paragraphs[para]).trim();
      if (text.isNotEmpty) {
        _followTtsBlock(i);
        var ok = true;
        // Android 引擎单次合成有长度上限，超长段落切段连读。
        for (var off = 0; off < text.length; off += 3000) {
          final end = (off + 3000) < text.length ? (off + 3000) : text.length;
          try {
            await _tts.speak(text.substring(off, end));
          } catch (_) {
            ok = false;
            break;
          }
          if (gen != _ttsGen || !mounted) return;
        }
        if (!ok) {
          _ttsGen++;
          if (mounted) {
            setState(() => _ttsActive = false);
            _toast('朗读失败，已停止');
          }
          return;
        }
      }
      if (gen != _ttsGen || !mounted) return;
      _ttsBlock++;
    }
    // 读完全书自然结束。
    if (gen == _ttsGen && mounted) {
      setState(() => _ttsActive = false);
    }
  }

  /// 让阅读视图跟随正在朗读的块：只在目标不在视野内时才动，
  /// 避免每段都强制跳转。
  void _followTtsBlock(int i) {
    if (!mounted) return;
    if (_pageTurnMode == PageTurnMode.scroll) {
      final positions = _positionsListener.itemPositions.value;
      final visible = positions.any((p) => p.index == i);
      if (visible) return;
      try {
        _scrollController.scrollTo(
          index: i,
          alignment: 0.15,
          duration: const Duration(milliseconds: 300),
        );
      } catch (_) {}
      return;
    }
    if (_pagesReady && !_pagesComputing) {
      if (Pagination.pageOf(_pageStarts, i) != _pageIndex) {
        _goToBlock(i);
      }
    } else {
      _restoreBlockTarget = i; // 分页算好后自动落位
    }
  }

  Future<void> _ttsStop() async {
    _ttsGen++;
    if (mounted && _ttsActive) setState(() => _ttsActive = false);
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> _showTtsSpeedSheet() async {
    final theme = readingThemes[_themeIndex];
    const speeds = [
      ('慢', 0.5),
      ('正常', 1.0),
      ('快', 1.5),
      ('更快', 2.0),
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
                '听书语速',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.text,
                ),
              ),
            ),
            for (final (label, rate) in speeds)
              ListTile(
                title: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: (_ttsSpeed == rate)
                        ? AppColors.accentLight
                        : theme.text,
                    fontWeight: (_ttsSpeed == rate)
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final wasActive = _ttsActive;
                  await _ttsStop();
                  setState(() => _ttsSpeed = rate);
                  final sp = await SharedPreferences.getInstance();
                  await sp.setDouble('tts_speed', rate);
                  _ttsReady = false; // 换语速后重新初始化引擎
                  if (wasActive) await _startTts();
                },
              ),
            ListTile(
              title: Text(
                _ttsActive ? '停止朗读' : '开始朗读',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: _ttsActive ? theme.secondaryText : AppColors.accentLight,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                if (_ttsActive) {
                  _ttsStop();
                } else {
                  _startTts();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---- 自定义字体 ----
  Future<void> _importCustomFont() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    if (files.isEmpty || files.first.path == null) return;
    try {
      final stored = await CustomFont.copyImported(files.first.path!);
      await CustomFont.register(stored);
      final loaded = await CustomFont.ensureLoaded();
      if (!mounted) return;
      if (!loaded) {
        _toast('字体加载失败');
        return;
      }
      setState(() => _fontFamily = CustomFont.family);
      _settingsSaveTimer?.cancel();
      _settingsSaveTimer =
          Timer(const Duration(milliseconds: 400), _saveSettings);
      _toast('自定义字体已启用');
      // 重算分页（缓存键含字体名，自动走新计算）。
      if (_pageTurnMode != PageTurnMode.scroll) {
        setState(() => _pagesCacheKey = '');
      }
    } catch (e) {
      _toast('导入失败：$e');
    }
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
                  Icon(Icons.error_outline,
                      size: 56, color: theme.secondaryText),
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
      // 重排版期间继续显示旧分页（保持可读，算完静默切换）；
      // 只在还没有任何分页结果时显示进度圈。
      content = _pageStarts.isNotEmpty
          ? _buildPaged(theme)
          : Center(child: CircularProgressIndicator(color: theme.text));
    } else {
      content = ScrollablePositionedList.builder(
        key: ValueKey<int>(_listAnchor),
        initialScrollIndex: _listAnchor,
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
        onTapUp: (d) => _onTapUp(d.localPosition),
        onHorizontalDragEnd: pageMode && _pageTurnMode != PageTurnMode.slide
            ? _onHorizontalDragEnd
            : null,
        child: Stack(
          children: [
            content,
            if (_autoScrolling || _ttsActive)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    if (_autoScrolling) _buildAutoPill(theme),
                    if (_ttsActive) _buildTtsPill(theme),
                  ],
                ),
              ),
            // 亮度遮罩：应用内降暗，盖在正文 + overlay 之上，点击穿透。
            if (_brightness < 1.0)
              IgnorePointer(
                child: Container(
                  color:
                      Colors.black.withValues(alpha: (1 - _brightness) * 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 当前排版/尺寸对应的分页缓存键（含书 id，不同书互不串用）。
  String _currentPagesKey() {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    return '${widget.book.id}|$_fontSize|$_lineHeight|$_fontFamily|'
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
      final sw = Stopwatch()..start();
      // 同一排版只全书计算一次：命中磁盘缓存直接载入。
      PaginateResult? cached = await PaginationCache.load(key);
      final PaginateResult result;
      if (cached != null) {
        result = cached;
        debugPrint('分页缓存命中 页数=${result.starts.length - 1} '
            '耗时=${sw.elapsedMilliseconds}ms');
      } else {
        result = await paginateAsync(PaginationArgs(
          chapters: _chapters,
          chapterStarts: _chapterStarts,
          totalBlocks: _totalBlocks(),
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          fontFamily: _fontFamily,
          width: size.width,
          height: size.height - padding.top - padding.bottom - 24 - 64,
        ));
        debugPrint('分页完成 页数=${result.starts.length - 1} '
            '耗时=${sw.elapsedMilliseconds}ms');
        unawaited(PaginationCache.save(key, result));
      }
      if (!mounted) return;
      // 计算期间排版参数又变了：丢弃旧结果，下次 build 会重新调度。
      if (_currentPagesKey() != key) return;
      // 保留阅读位置：在新排版里定位当前块所在页，而不是跳回第 0 页。
      final total = _totalBlocks();
      final block = total > 0 ? _currentIndex.clamp(0, total - 1) : 0;
      setState(() {
        _pageStarts = result.starts;
        _pageChars = result.chars;
        _pagesCacheKey = key;
        _pageIndex = Pagination.pageOf(result.starts, block);
      });
      if (_pageTurnMode == PageTurnMode.slide && _pageController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(_pageIndex);
          }
        });
      }
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
    if (_pageAnimating &&
        _pageTurnMode == PageTurnMode.simulation &&
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
    if (_pageAnimating &&
        _pageTurnMode == PageTurnMode.simulation &&
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
      var segEnd =
          !isEndBlock || endC == 0 ? txt.length : endC.clamp(cur, txt.length);
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

  /// 自动阅读进行时的悬浮胶囊。
  Widget _buildAutoPill(ReadingTheme theme) {
    return Center(
      child: GestureDetector(
        onTap: _pauseAutoScroll,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: theme.background.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
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
    );
  }

  /// 听书进行时的悬浮胶囊（点击停止）。
  Widget _buildTtsPill(ReadingTheme theme) {
    return Center(
      child: GestureDetector(
        onTap: _ttsStop,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: theme.background.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.record_voice_over,
                  size: 16, color: AppColors.accentLight),
              const SizedBox(width: 6),
              Text(
                '听书中（点击停止）',
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
    );
  }
}

/// 章节目录底部面板：打开即滚动定位到当前章节，带可拖动滑动条，
/// 右上角可全文搜索、切换正序/倒序（倒序 = 最新章在最前）。
class _ChapterListSheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentChapter;
  final ReadingTheme theme;
  final bool descending;
  final ValueChanged<bool> onDescendingChanged;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;

  const _ChapterListSheet({
    required this.chapters,
    required this.currentChapter,
    required this.theme,
    required this.descending,
    required this.onDescendingChanged,
    required this.onSelect,
    required this.onSearch,
  });

  @override
  State<_ChapterListSheet> createState() => _ChapterListSheetState();
}

class _ChapterListSheetState extends State<_ChapterListSheet> {
  final ScrollController _scrollController = ScrollController();
  late bool _desc = widget.descending;
  static const double _itemExtent = 52;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrent());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScrolled);
    _scrollController.dispose();
    super.dispose();
  }

  /// 列表滚动时刷新 thumb 位置（拖动中由 _dragRatio 接管，跳过）。
  void _onScrolled() {
    if (_dragRatio != null || !mounted) return;
    setState(() {});
  }

  /// 章节下标 → 显示列表中的行下标（倒序时整体反转）。
  int _displayRow(int chapterIndex) =>
      _desc ? widget.chapters.length - 1 - chapterIndex : chapterIndex;

  void _jumpToCurrent() {
    if (!_scrollController.hasClients) return;
    final target = (_displayRow(widget.currentChapter) * _itemExtent - 80)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(target);
  }

  // ---- 右侧快跳滑条 ----
  double? _dragRatio; // 拖动中的比例（null = 未在拖动）

  void _onTrackDrag(double dy, double trackH) {
    if (!_scrollController.hasClients || trackH <= 0) return;
    final ratio = (dy / trackH).clamp(0.0, 1.0);
    setState(() => _dragRatio = ratio);
    _scrollController
        .jumpTo(ratio * _scrollController.position.maxScrollExtent);
  }

  Widget _buildFastTrack(double trackH) {
    final theme = widget.theme;
    final hasClients = _scrollController.hasClients;
    final max = hasClients ? _scrollController.position.maxScrollExtent : 0.0;
    final ratio = _dragRatio ??
        (hasClients && max > 0
            ? (_scrollController.offset / max).clamp(0.0, 1.0)
            : 0.0);
    final thumbH = 44.0;
    final innerH = trackH - 24;
    final thumbTop = 12 + ratio * (innerH - thumbH).clamp(0.0, innerH);

    final n = widget.chapters.length;
    String? bubble;
    if (_dragRatio != null && n > 0 && max > 0) {
      final row = (ratio * max / _itemExtent).round().clamp(0, n - 1);
      final ci = _desc ? n - 1 - row : row;
      final t = widget.chapters[ci].title;
      bubble = t.isEmpty
          ? '第 ${ci + 1} 章'
          : (t.length > 8 ? '${t.substring(0, 8)}…' : t);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (d) => _onTrackDrag(d.localPosition.dy, trackH),
      onVerticalDragUpdate: (d) => _onTrackDrag(d.localPosition.dy, trackH),
      onVerticalDragCancel: () => setState(() => _dragRatio = null),
      onVerticalDragEnd: (_) => setState(() => _dragRatio = null),
      // 气泡比 34px 命中区宽，关掉裁剪才能完整显示在轨道左侧。
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerRight,
        children: [
          Positioned(
            right: 8,
            top: 12,
            bottom: 12,
            width: 6,
            child: Container(
              decoration: BoxDecoration(
                color: theme.secondaryText.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Positioned(
            right: 5,
            top: thumbTop,
            width: 12,
            height: thumbH,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          if (bubble != null)
            Positioned(
              right: 26,
              top: (thumbTop - 8).clamp(0.0, trackH - 40),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.background.withValues(alpha: 0.95),
                  border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  bubble,
                  style: TextStyle(fontSize: 12, color: theme.text),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final primary = Theme.of(context).colorScheme.primary;
    final n = widget.chapters.length;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '目录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: theme.text,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.search, color: theme.secondaryText),
                    tooltip: '全文搜索',
                    onPressed: widget.onSearch,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.secondaryText.withValues(alpha: 0.35),
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<bool>(
                        value: _desc,
                        dropdownColor: theme.background,
                        icon: Icon(Icons.arrow_drop_down,
                            color: theme.secondaryText),
                        style: TextStyle(fontSize: 13, color: theme.text),
                        items: const [
                          DropdownMenuItem(value: false, child: Text('正序')),
                          DropdownMenuItem(value: true, child: Text('倒序')),
                        ],
                        onChanged: (v) {
                          if (v == null || v == _desc) return;
                          setState(() => _desc = v);
                          widget.onDescendingChanged(v);
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => _jumpToCurrent());
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(builder: (ctx, cons) {
                return Stack(
                  children: [
                    ListView.builder(
                      controller: _scrollController,
                      itemExtent: _itemExtent,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: n,
                      itemBuilder: (ctx, row) {
                        final i = _desc ? n - 1 - row : row;
                        final selected = i == widget.currentChapter;
                        final title = widget.chapters[i].title.isEmpty
                            ? '第 ${i + 1} 章'
                            : widget.chapters[i].title;
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
                          onTap: () => widget.onSelect(i),
                        );
                      },
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 34,
                      child: _buildFastTrack(cons.maxHeight),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条搜索命中：章节/段落定位 + 关键词位置（用于高亮片段）。
class _SearchHit {
  final int block; // 跳转用区块下标
  final String chapterTitle;
  final String text; // 命中所在整段文本
  final int start; // 命中起点（按原文本）
  final int len; // 命中长度

  const _SearchHit({
    required this.block,
    required this.chapterTitle,
    required this.text,
    required this.start,
    required this.len,
  });
}

/// 全书文本扫描（主线程一次跑完；先画出一帧「搜索中」再扫描，
/// 避免白屏感。上限 300 条防止极端关键词刷爆列表）。
List<_SearchHit> searchBook(
  List<Chapter> chapters,
  List<int> chapterStarts,
  String needle,
) {
  final lower = needle.toLowerCase();
  final hits = <_SearchHit>[];
  String chapterTitleOf(int c) {
    final t = chapters[c].title;
    return t.isEmpty ? '第 ${c + 1} 章' : t;
  }

  for (var c = 0; c < chapters.length && hits.length < 300; c++) {
    final title = chapters[c].title;
    final lowerTitle = title.toLowerCase();
    if (lowerTitle.contains(lower)) {
      hits.add(_SearchHit(
        block: chapterStarts[c],
        chapterTitle: chapterTitleOf(c),
        text: title,
        start: lowerTitle.indexOf(lower),
        len: needle.length,
      ));
    }
    final paras = chapters[c].paragraphs;
    for (var pi = 0; pi < paras.length && hits.length < 300; pi++) {
      final text = paras[pi];
      if (text.isEmpty) continue;
      final lt = text.toLowerCase();
      var from = 0;
      while (hits.length < 300) {
        final idx = lt.indexOf(lower, from);
        if (idx < 0) break;
        hits.add(_SearchHit(
          block: chapterStarts[c] + 1 + pi,
          chapterTitle: chapterTitleOf(c),
          text: text,
          start: idx,
          len: needle.length,
        ));
        from = idx + needle.length;
      }
    }
  }
  return hits;
}

/// 书内全文搜索面板：目录页右上角放大镜进入。
class _SearchSheet extends StatefulWidget {
  final List<Chapter> chapters;
  final List<int> chapterStarts;
  final ReadingTheme theme;
  final ValueChanged<int> onJump;

  const _SearchSheet({
    required this.chapters,
    required this.chapterStarts,
    required this.theme,
    required this.onJump,
  });

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();
  List<_SearchHit> _results = [];
  bool _searched = false;
  bool _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final needle = _controller.text.trim();
    if (needle.isEmpty || _searching) return;
    setState(() => _searching = true);
    // 先让「搜索中」画一帧，再执行同步扫描。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 避免闭包隐式捕获 widget（跨 isolate 不可发送），先取局部变量。
    final chapters = widget.chapters;
    final starts = widget.chapterStarts;
    final hits = searchBook(chapters, starts, needle);
    if (!mounted) return;
    setState(() {
      _results = hits;
      _searching = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Padding(
      // 键盘弹起时面板随之抬高。
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _run(),
                      style: TextStyle(fontSize: 15, color: theme.text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索正文 / 章节名',
                        hintStyle:
                            TextStyle(fontSize: 14, color: theme.secondaryText),
                        filled: true,
                        fillColor: theme.secondaryText.withValues(alpha: 0.10),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                    ),
                    onPressed: _searching ? null : _run,
                    child: const Text('搜索'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildResults(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ReadingTheme theme) {
    if (_searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: theme.text),
            const SizedBox(height: 12),
            Text('正在搜索…',
                style: TextStyle(fontSize: 13, color: theme.secondaryText)),
          ],
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Text('输入关键词，搜索本书全文',
            style: TextStyle(fontSize: 13, color: theme.secondaryText)),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('没有找到「${_controller.text.trim()}」',
            style: TextStyle(fontSize: 13, color: theme.secondaryText)),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final h = _results[i];
        return ListTile(
          dense: true,
          title: Text(
            h.chapterTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: theme.secondaryText,
            ),
          ),
          subtitle: _buildSnippet(h, theme),
          onTap: () => widget.onJump(h.block),
        );
      },
    );
  }

  /// 命中片段：关键词前后各取 ~16 字，关键词高亮。
  Widget _buildSnippet(_SearchHit h, ReadingTheme theme) {
    const margin = 16;
    final start = (h.start - margin).clamp(0, h.text.length);
    final end = (h.start + h.len + margin).clamp(0, h.text.length);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 14, color: theme.text),
        children: [
          if (start > 0) const TextSpan(text: '…'),
          TextSpan(text: h.text.substring(start, h.start)),
          TextSpan(
            text: h.text.substring(h.start, h.start + h.len),
            style: const TextStyle(
              color: AppColors.accentLight,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: h.text.substring(h.start + h.len, end)),
          if (end < h.text.length) const TextSpan(text: '…'),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
