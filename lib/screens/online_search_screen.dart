import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../services/book_library.dart';
import '../services/guishuji_source.dart';
import '../theme/app_colors.dart';
import 'reader_screen.dart';

const Map<String, String> _categoryEmoji = {
  'kehuan': '🚀',
  'wuxia': '⚔️',
  'yanqing': '💕',
  'dushi': '🏙️',
  'kongbu': '👻',
  'lingyi': '🕯️',
  'daomu': '⛏️',
  'daoshi': '🧙',
  'wangluo': '💻',
  'gudian': '🏮',
  'waiguo': '🌍',
  'xiandai': '📱',
  'guoxue': '📜',
  'sanwen': '🍃',
  'ys': '🎬',
};

/// 在线找书：原生分类浏览（不再内嵌 WebView）。
///
/// 搜索接口被 Cloudflare 拦截（需 JS 挑战），故改用「分类 → 书单 → 详情/下载」的原生链路，
/// 由 App 直接解析网页并返回结果。
class OnlineSearchScreen extends StatelessWidget {
  const OnlineSearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('在线找书')),
      body: Column(
        children: [
          _PasteUrlBanner(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PasteUrlScreen()),
              );
            },
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.1,
              ),
              itemCount: guishujiCategories.length,
              itemBuilder: (context, i) {
                final category = guishujiCategories.keys.elementAt(i);
                final name = guishujiCategories[category]!;
                return _CategoryCard(
                  emoji: _categoryEmoji[category] ?? '📚',
                  name: name,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CategoryBooksScreen(
                          category: category,
                          categoryName: name,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PasteUrlBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _PasteUrlBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: AppColors.gradient),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.link, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '粘贴目录地址下载',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    '把书的目录页/章节页链接粘进来，自动下载整本',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final String emoji;
  final String name;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.emoji,
    required this.name,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 某个分类下的书单，支持「加载更多」分页。
class CategoryBooksScreen extends StatefulWidget {
  final String category;
  final String categoryName;

  const CategoryBooksScreen({
    super.key,
    required this.category,
    required this.categoryName,
  });

  @override
  State<CategoryBooksScreen> createState() => _CategoryBooksScreenState();
}

class _CategoryBooksScreenState extends State<CategoryBooksScreen> {
  final List<BookItem> _books = [];
  int _page = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = _page > 0);
    try {
      final items =
          await GuishujiSource.fetchCategoryBooks(widget.category, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page++;
        _books.addAll(items);
        _hasMore = items.isNotEmpty;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.categoryName)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _books.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: () {
              setState(() {
                _loading = true;
                _error = null;
              });
              _load();
            }, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_books.isEmpty) {
      return const Center(
        child: Text('该分类暂无书籍', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _books.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (i == _books.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.tonal(
              onPressed: _loadingMore ? null : _load,
              child: _loadingMore
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加载更多'),
            ),
          );
        }
        final book = _books[i];
        return _BookRow(
          book: book,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BookDetailScreen(book: book)),
            );
          },
        );
      },
    );
  }
}

class _BookRow extends StatelessWidget {
  final BookItem book;
  final VoidCallback onTap;

  const _BookRow({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(url: book.coverFullUrl, width: 58, height: 82),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  if (book.author.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.accentLight,
                      ),
                    ),
                  ],
                  if (book.intro.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      book.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 书籍详情：封面 + 书名/作者 + 章数 + 「下载本书」。
class BookDetailScreen extends StatefulWidget {
  final BookItem book;

  const BookDetailScreen({super.key, required this.book});

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  CatalogInfo? _info;
  bool _loadingInfo = true;
  String? _infoError;

  bool _downloading = false;
  bool _cancelled = false;
  String _status = '';
  double? _progress;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await GuishujiSource.fetchCatalogInfo(widget.book.catalogUrl);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loadingInfo = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _infoError = '获取书籍信息失败：$e';
        _loadingInfo = false;
      });
    }
  }

  Future<void> _download() async {
    if (_downloading) return;
    final info = _info;
    if (info == null) {
      _toast('书籍信息尚未加载完成');
      return;
    }

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
        widget.book.catalogUrl,
        isCancelled: () => _cancelled,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _status = '正在抓取章节 $done / $total';
            _progress = done / total;
          });
        },
      );
      await _addToLibrary(result);
      if (!mounted) return;
      setState(() => _downloading = false);
      _showDone(result);
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

  Future<void> _addToLibrary(DownloadResult r) async {
    await BookLibrary().addDownloadedBook(
      r.filePath,
      r.title,
      r.author,
      coverTempPath: r.coverFilePath,
    );
  }

  void _showDone(DownloadResult r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载完成'),
        content: Text('《${r.title}》已加入书架（${r.chapterCount} 章）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('留在本页'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('回书架阅读'),
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
    final book = widget.book;
    return Scaffold(
      appBar: AppBar(title: Text(book.title)),
      body: Stack(
        children: [
          _buildContent(book),
          if (_downloading) _buildDownloadOverlay(),
        ],
      ),
    );
  }

  Widget _buildContent(BookItem book) {
    if (_loadingInfo) {
      return const Center(child: CircularProgressIndicator());
    }
    final info = _info;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(url: book.coverFullUrl, width: 96, height: 136),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    info == null
                        ? '作者：${book.author.isEmpty ? '未知' : book.author}'
                        : '作者：${info.author.isEmpty ? '未知' : info.author}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.accentLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (info != null)
                    Text(
                      '共 ${info.chapterCount} 章',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_infoError != null) ...[
          const SizedBox(height: 16),
          Text(
            _infoError!,
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
        if (book.intro.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            '内容简介',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.intro,
            style: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (_info != null && !_downloading) ? _download : null,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('下载本书'),
          ),
        ),
      ],
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

/// 封面图（网络加载失败时回退到渐变 + emoji 占位）。
class _Cover extends StatelessWidget {
  final String url;
  final double width;
  final double height;

  const _Cover({required this.url, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3B2F63), Color(0xFF241B40)],
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('📖', style: TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

/// 粘贴目录地址 → 自动下载整本 → 加入书架 → 打开阅读。
class PasteUrlScreen extends StatefulWidget {
  const PasteUrlScreen({super.key});

  @override
  State<PasteUrlScreen> createState() => _PasteUrlScreenState();
}

class _PasteUrlScreenState extends State<PasteUrlScreen> {
  final TextEditingController _controller = TextEditingController();

  bool _downloading = false;
  bool _cancelled = false;
  String _status = '';
  double? _progress;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() => _controller.text = data.text!.trim());
    }
  }

  Future<void> _start() async {
    if (_downloading) return;
    final input = _controller.text.trim();
    if (input.isEmpty) {
      _toast('请先粘贴书籍目录页或章节页链接');
      return;
    }
    final catalogUrl = GuishujiSource.resolveCatalogUrl(input);
    if (catalogUrl == null) {
      _toast('无法识别该链接，请粘贴书籍目录页（如 …/kehuan/12453/）');
      return;
    }

    CatalogInfo info;
    try {
      info = await GuishujiSource.fetchCatalogInfo(catalogUrl);
    } catch (e) {
      _toast('获取书籍信息失败：$e');
      return;
    }

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
            onPressed: () {
              Navigator.pop(ctx); // 关对话框
              Navigator.pop(context); // 关粘贴页
            },
            child: const Text('完成'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx); // 关对话框
              Navigator.of(context).pushReplacement(
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
    return Scaffold(
      appBar: AppBar(title: const Text('粘贴地址下载')),
      body: Stack(
        children: [
          _buildForm(),
          if (_downloading) _buildDownloadOverlay(),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            maxLines: 3,
            minLines: 1,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: '粘贴书籍目录页或章节页链接\n例如 https://m.guishuji.com/kehuan/12453/',
              hintStyle: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: const EdgeInsets.all(14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: '粘贴剪贴板',
                onPressed: _paste,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '提示：在浏览器里打开某本书的目录页或任一章节页，复制地址粘进来即可，App 会自动解析并下载整本。',
            style: TextStyle(fontSize: 12, height: 1.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _downloading ? null : _start,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('下载并加入书架'),
            ),
          ),
        ],
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
