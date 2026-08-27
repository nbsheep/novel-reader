import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/book_library.dart';
import '../services/book_parser.dart';
import '../services/bookmarks.dart';
import '../services/reading_stats.dart';
import '../theme/app_colors.dart';
import 'online_search_screen.dart';
import 'reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final BookLibrary _library = BookLibrary();
  List<Book> _books = [];
  Map<String, double> _progressRatios = {};
  Map<String, String> _chapterLabels = {};
  int _totalReadSeconds = 0;
  bool _loading = true;
  bool _importing = false;

  String _sortMode = 'added'; // added / recent / title
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final books = await _library.load();
    final totalSeconds = await ReadingStats.getTotalSeconds();
    final sp = await SharedPreferences.getInstance();
    _sortMode = sp.getString('sort_mode') ?? 'added';
    final ratios = <String, double>{};
    final labels = <String, String>{};
    for (final b in books) {
      ratios[b.id] = sp.getDouble('progress_${b.id}_ratio') ?? 0.0;
      labels[b.id] = sp.getString('progress_${b.id}_chapter') ?? '';
    }
    books.sort(_compareBooks);
    if (!mounted) return;
    setState(() {
      _books = books;
      _totalReadSeconds = totalSeconds;
      _progressRatios = ratios;
      _chapterLabels = labels;
      _loading = false;
    });
  }

  Future<void> _import() async {
    if (_importing) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
    );
    if (files.isEmpty) return;

    setState(() => _importing = true);
    try {
      for (final f in files) {
        if (f.path == null) continue;
        await _addBook(f.path!, f.name);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
      await _reload();
    }
  }

  Future<void> _addBook(String srcPath, String fileName) async {
    try {
      final ext = p.extension(fileName).toLowerCase();
      final format = ext == '.epub' ? BookFormat.epub : BookFormat.txt;
      final target = await _library.copyToLibrary(srcPath, fileName);

      // 验证文件是否成功复制
      if (!File(target).existsSync()) {
        throw Exception('文件复制失败：$target');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final id = now.toString();

      var title = p.basenameWithoutExtension(fileName);
      var author = '';
      var wordCount = 0;
      String? coverPath;

      // EPUB 优先取书内元数据 + 内嵌封面；TXT 直接用文件名，避免重复全量解析。
      if (format == BookFormat.epub) {
        try {
          final parsed = await parseBook(Book(
            id: id,
            title: title,
            author: '',
            filePath: target,
            format: format,
            addedAt: now,
          ));
          if (parsed.title.isNotEmpty) title = parsed.title;
          author = parsed.author;
          wordCount = parsed.wordCount;
          if (parsed.coverBytes != null) {
            coverPath = await _library.saveCoverBytes(
              id,
              parsed.coverBytes!,
              ext: parsed.coverExt.isEmpty ? '.jpg' : parsed.coverExt,
            );
          }
        } catch (e) {
          // EPUB 解析失败时，使用文件名作为标题
          print('EPUB解析失败: $e');
        }
      }

      final books = await _library.load();
      books.insert(
        0,
        Book(
          id: id,
          title: title,
          author: author,
          filePath: target,
          format: format,
          addedAt: now,
          wordCount: wordCount,
          coverPath: coverPath,
        ),
      );
      await _library.save(books);
    } catch (e) {
      // 导入失败时显示错误
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e'), duration: const Duration(seconds: 3)),
        );
      }
    }
  }

  Future<void> _delete(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定删除《${book.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _library.remove(book);
    await _clearBookData(book.id);
    await _reload();
  }

  /// 删除一本书时一并清理其进度与书签（SharedPreferences）。
  Future<void> _clearBookData(String id) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('progress_$id');
    await sp.remove('progress_${id}_ratio');
    await sp.remove('progress_${id}_chapter');
    await BookmarkStore.clear(id);
  }

  int _compareBooks(Book a, Book b) {
    switch (_sortMode) {
      case 'recent':
        if (a.lastReadAt != b.lastReadAt) return b.lastReadAt.compareTo(a.lastReadAt);
        return b.addedAt.compareTo(a.addedAt);
      case 'title':
        return a.title.compareTo(b.title);
      default: // added
        return b.addedAt.compareTo(a.addedAt);
    }
  }

  Future<void> _showSortSheet() async {
    const options = [
      ('recent', '最近阅读'),
      ('added', '最近添加'),
      ('title', '书名'),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '排序方式',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            for (final (value, label) in options)
              ListTile(
                leading: Icon(
                  value == _sortMode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: value == _sortMode
                      ? AppColors.accent
                      : AppColors.textSecondary,
                ),
                title: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (value == _sortMode) return;
                  setState(() => _sortMode = value);
                  final sp = await SharedPreferences.getInstance();
                  await sp.setString('sort_mode', value);
                  await _reload();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showBookMenu(Book book) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
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
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined,
                  color: AppColors.accentLight),
              title: const Text('更换封面',
                  style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _changeCover(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: AppColors.textSecondary),
              title: const Text('删除',
                  style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(book);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _changeCover(Book book) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final path = await _library.saveCoverBytes(book.id, bytes, ext: '.jpg');
    if (path == null) return;
    await _library.setCover(book.id, path);
    await _reload();
  }

  void _enterSelecting() {
    setState(() {
      _selecting = true;
      _selected.clear();
    });
  }

  void _exitSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(Book book) {
    setState(() {
      if (!_selected.remove(book.id)) _selected.add(book.id);
    });
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定删除选中的 ${_selected.length} 本书吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final id in _selected.toList()) {
      final book = _books.firstWhere((b) => b.id == id);
      await _library.remove(book);
      await _clearBookData(id);
    }
    _exitSelecting();
    await _reload();
  }

  Future<void> _open(Book book) async {
    // 检查文件路径是否为空
    if (book.filePath.isEmpty) {
      _showErrorDialog('文件路径为空', '《${book.title}》的文件路径为空，无法打开。请删除这本书后重新导入。');
      return;
    }

    // 检查文件是否存在
    final file = File(book.filePath);
    if (!file.existsSync()) {
      _showErrorDialog('文件不存在', '《${book.title}》的文件不存在。\n\n可能已被删除或移动，请删除这本书后重新导入。');
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
    );
    await _reload();
  }

  void _showErrorDialog(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _openOnlineSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OnlineSearchScreen()),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selecting ? _buildSelectingAppBar() : _buildNormalAppBar(),
      body: _buildBody(),
    );
  }

  AppBar _buildNormalAppBar() {
    return AppBar(
      title: _gradientTitle('书架'),
      centerTitle: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.public),
          tooltip: '在线找书',
          onPressed: _openOnlineSearch,
        ),
        IconButton(
          icon: _importing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          tooltip: '导入小说',
          onPressed: _importing ? null : _import,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          onSelected: (v) {
            if (v == 'sort') _showSortSheet();
            if (v == 'multi') _enterSelecting();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'sort', child: Text('排序')),
            PopupMenuItem(value: 'multi', child: Text('多选删除')),
          ],
        ),
      ],
    );
  }

  AppBar _buildSelectingAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: '取消',
        onPressed: _exitSelecting,
      ),
      title: Text(
        '已选 ${_selected.length} 本',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      centerTitle: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: '删除选中',
          onPressed: _selected.isEmpty ? null : _batchDelete,
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_books.isEmpty) {
      return _buildEmpty();
    }
    final continueBook = _continueBook();
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildStatsCard()),
        if (continueBook != null)
          SliverToBoxAdapter(child: _buildContinueCard(continueBook)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 14,
              childAspectRatio: 0.52,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final book = _books[i];
                return _BookCard(
                  book: book,
                  progressRatio:
                      (_progressRatios[book.id] ?? 0.0).clamp(0.0, 1.0),
                  selecting: _selecting,
                  selected: _selected.contains(book.id),
                  onTap: () => _selecting ? _toggleSelected(book) : _open(book),
                  onLongPress: _selecting ? null : () => _showBookMenu(book),
                );
              },
              childCount: _books.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _gradientTitle(String text) {
    return ShaderMask(
      shaderCallback: (r) =>
          const LinearGradient(colors: AppColors.gradient).createShader(r),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  // ---- 统计卡片 ----
  Widget _buildStatsCard() {
    // 已读总字数 = Σ(每本字数 × 阅读进度)，反映实际读完的字数。
    final readWords = _books.fold<int>(0, (a, b) {
      final ratio = (_progressRatios[b.id] ?? 0.0).clamp(0.0, 1.0);
      return a + (b.wordCount * ratio).round();
    });
    final readBooks = _books.where((b) => b.readSeconds > 0).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _stat(ReadingStats.formatDuration(_totalReadSeconds), '累计阅读'),
          _stat(ReadingStats.formatWordCount(readWords), '已读总字数'),
          _stat('$readBooks 本', '已读'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: AppColors.gradient,
            ).createShader(r),
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  // ---- 继续阅读 ----
  Book? _continueBook() {
    Book? best;
    for (final b in _books) {
      if (b.lastReadAt > 0 && (best == null || b.lastReadAt > best.lastReadAt)) {
        best = b;
      }
    }
    return best;
  }

  Widget _buildContinueCard(Book book) {
    final ratio = (_progressRatios[book.id] ?? 0.0).clamp(0.0, 1.0);
    final percent = (ratio * 100).round();
    final colors = _coverColors(book.title);
    final chapterLabel = _chapterLabels[book.id] ?? '';
    final subtitle = chapterLabel.isNotEmpty ? chapterLabel : book.author;
    return GestureDetector(
      onTap: () => _open(book),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _coverThumb(book, colors),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '继续阅读',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.accentLight,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$percent%',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentLight,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _gradientProgressBar(ratio),
          ],
        ),
      ),
    );
  }

  Widget _coverThumb(Book book, List<Color> colors) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 62,
        child: _coverContent(book, colors, fontSize: 18),
      ),
    );
  }

  Widget _gradientProgressBar(double ratio) {
    return SizedBox(
      width: double.infinity,
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            Container(color: AppColors.border),
            FractionallySizedBox(
              widthFactor: ratio,
              heightFactor: 1.0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: AppColors.gradient),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_stories, size: 72, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          const Text(
            '书架还是空的',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '导入 .txt 或 .epub 小说开始阅读',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _importing ? null : _import,
            icon: const Icon(Icons.add),
            label: const Text('导入小说'),
          ),
        ],
      ),
    );
  }
}

/// 书架卡片：封面 emoji + 书名 + 作者/字数/时长/进度 meta。
class _BookCard extends StatelessWidget {
  final Book book;
  final double progressRatio;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _BookCard({
    required this.book,
    required this.progressRatio,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _coverColors(book.title);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: colors.last.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _coverContent(book, colors, fontSize: 28),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _formatBadge(book.format),
                    ),
                    if (progressRatio > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _coverProgress(progressRatio),
                      ),
                    if (selecting)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _selectionDot(selected),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            _bookMeta(book),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _coverProgress(double ratio) {
    return Container(
      height: 4,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
        color: Colors.black.withValues(alpha: 0.35),
      ),
      child: FractionallySizedBox(
        widthFactor: ratio.clamp(0.0, 1.0),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: AppColors.gradient),
          ),
        ),
      ),
    );
  }

  Widget _selectionDot(bool isSelected) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected
            ? AppColors.accent
            : Colors.black.withValues(alpha: 0.4),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: isSelected
          ? const Icon(Icons.check, size: 13, color: Colors.white)
          : null,
    );
  }

  String _bookMeta(Book book) {
    final parts = <String>[];
    if (book.author.isNotEmpty) parts.add(book.author);
    if (book.wordCount > 0) {
      parts.add(ReadingStats.formatWordCount(book.wordCount));
    }
    if (progressRatio > 0) parts.add('${(progressRatio * 100).round()}%');
    if (book.readSeconds >= 60) {
      parts.add('已读${ReadingStats.formatDuration(book.readSeconds)}');
    }
    return parts.join(' · ');
  }

  Widget _formatBadge(BookFormat format) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        format == BookFormat.epub ? 'EPUB' : 'TXT',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 封面内容：有本地封面图则显示图片，否则书名文字占位。
Widget _coverContent(Book book, List<Color> colors, {double fontSize = 28}) {
  final coverPath = book.coverPath;
  if (coverPath != null && File(coverPath).existsSync()) {
    return Image.file(
      File(coverPath),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _coverFallback(book, colors, fontSize),
    );
  }
  return _coverFallback(book, colors, fontSize);
}

/// 无封面时的占位：渐变 + 书名前两个字。
Widget _coverFallback(Book book, List<Color> colors, double fontSize) {
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    ),
    alignment: Alignment.center,
    child: Text(
      _coverText(book.title),
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        color: Colors.white.withValues(alpha: 0.92),
        letterSpacing: 2,
      ),
    ),
  );
}

/// 取书名前两个字符作为封面文字（空书名兜底）。
String _coverText(String title) {
  if (title.isEmpty) return '书';
  final runes = title.runes.toList();
  if (runes.length >= 2) return String.fromCharCodes(runes.take(2));
  return title;
}

/// 深色调色板：按书名 hash 取封面渐变色。
List<Color> _coverColors(String seed) {
  const palettes = [
    [Color(0xFF3B2F63), Color(0xFF241B40)],
    [Color(0xFF3A2A5E), Color(0xFF1F1A3A)],
    [Color(0xFF2E3A6E), Color(0xFF1B2344)],
    [Color(0xFF5B2D5A), Color(0xFF331A38)],
    [Color(0xFF2F5B7A), Color(0xFF1B3248)],
    [Color(0xFF4A3A2E), Color(0xFF2A2118)],
    [Color(0xFF2E5B4A), Color(0xFF18342B)],
    [Color(0xFF5B3A2E), Color(0xFF332119)],
  ];
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palettes[h % palettes.length];
}
