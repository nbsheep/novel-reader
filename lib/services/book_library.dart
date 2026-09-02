import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';

/// 书架：把书籍元信息持久化到应用文档目录下的 library.json，
/// 导入的文件拷贝到 books/ 子目录，避免依赖系统文件选择器返回的临时路径。
class BookLibrary {
  static const _indexName = 'library.json';

  /// 全局共享内存缓存：所有 BookLibrary 实例共用同一份数据。
  /// 之前各实例各留一份旧列表、整份写回，后写的会覆盖别人刚删掉的
  /// 结果（删除的书"复活"）——共享缓存 + 写串行化共同杜绝。
  static List<Book>? _cache;

  /// 写操作串行队列：读取→修改→落盘全程独占，避免交错覆盖。
  static Future<void> _writeQueue = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _writeQueue.then((_) => op());
    _writeQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> _booksDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'books'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _coversDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'covers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _indexFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, _indexName));
  }

  List<Book> _parseIndex(String content) {
    final rawList = json.decode(content) as List<dynamic>;
    final books = <Book>[];
    for (final e in rawList) {
      try {
        books.add(Book.fromJson(e as Map<String, dynamic>));
      } catch (_) {}
    }
    return books;
  }

  /// 队列内的干净读取：优先共享缓存，否则读盘（不做自愈改写）。
  Future<List<Book>> _freshCopy() async {
    final cached = _cache;
    if (cached != null) return List.of(cached);
    try {
      final f = await _indexFile();
      if (!await f.exists()) return [];
      return _parseIndex(await f.readAsString());
    } catch (_) {
      return [];
    }
  }

  Future<List<Book>> load() async {
    final cached = _cache;
    if (cached != null) return List.of(cached);
    final f = await _indexFile();
    if (!await f.exists()) {
      _cache = [];
      return [];
    }

    List<Book>? books;
    try {
      books = _parseIndex(await f.readAsString());
    } catch (_) {
      // 解析失败时清除缓存，让下次重试
      _cache = null;
      return [];
    }

    // 自愈：丢掉书籍文件已不存在的条目（旧版删除 bug 留下的"僵尸"
    // 记录、或用户手动删了文件），否则它们永远躺在书架上。
    final missing = <String>[];
    books.removeWhere((b) {
      final gone = !File(b.filePath).existsSync();
      if (gone) missing.add('${b.title}(${b.id})');
      return gone;
    });
    if (missing.isNotEmpty) print('清理文件已丢失的书籍: $missing');

    _cache = List.of(books);
    // 有脏数据就异步把修正后的列表落盘。
    if (missing.isNotEmpty) {
      unawaited(_serialized(() => _persist(books!)));
    }
    return books;
  }

  Future<void> save(List<Book> books) => _serialized(() async {
        _cache = List.of(books);
        await _persist(books);
      });

  Future<void> _persist(List<Book> books) async {
    final f = await _indexFile();
    await f.writeAsString(
      json.encode(books.map((b) => b.toJson()).toList()),
    );
  }

  /// 把导入的文件拷贝进应用目录，重名自动加序号，返回目标路径。
  Future<String> copyToLibrary(String sourcePath, String fileName) async {
    final dir = await _booksDir();
    var target = p.join(dir.path, fileName);
    var i = 1;
    while (await File(target).exists()) {
      final ext = p.extension(fileName);
      final base = p.basenameWithoutExtension(fileName);
      target = p.join(dir.path, '$base($i)$ext');
      i++;
    }
    await File(sourcePath).copy(target);
    return target;
  }

  /// 删除一本书：先把条目从书架索引移除并落盘（否则刷新后仍会从
  /// library.json 加载回来），再清理书籍与封面文件。
  Future<void> remove(Book book) => _serialized(() async {
        final books = await _freshCopy();
        final before = books.length;
        books.removeWhere((b) => b.id == book.id || b.filePath == book.filePath);
        if (books.length == before && !await File(book.filePath).exists()) {
          // 条目本就不在且文件也不在：无事可做。
          return;
        }
        _cache = List.of(books);
        await _persist(books);
        try {
          final f = File(book.filePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
        final cp = book.coverPath;
        if (cp != null && cp.isNotEmpty) {
          try {
            final c = File(cp);
            if (await c.exists()) await c.delete();
          } catch (_) {}
        }
      });

  /// 把封面字节写入 covers/ 目录，返回路径；失败返回 null。
  Future<String?> saveCoverBytes(
    String bookId,
    List<int> bytes, {
    String ext = '.jpg',
  }) async {
    try {
      final dir = await _coversDir();
      final target = p.join(dir.path, '$bookId$ext');
      await File(target).writeAsBytes(bytes, flush: true);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 把下载好的临时 EPUB 加入书架，返回新建的 [Book]。
  Future<Book> addDownloadedBook(
    String tempFilePath,
    String title,
    String author, {
    String? coverTempPath,
    String? sourceCatalogUrl,
    int? sourceLastChapterId,
  }) =>
      _serialized(() async {
        final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
        final fileName = cleaned.isEmpty ? '下载书籍' : cleaned;
        final target = await copyToLibrary(tempFilePath, '$fileName.epub');
        final books = await _freshCopy();
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = now.toString();

        // 顺带把临时封面拷进 covers/ 目录。
        String? coverPath;
        if (coverTempPath != null && coverTempPath.isNotEmpty) {
          try {
            final ext = p.extension(coverTempPath).toLowerCase();
            final coverTarget = p.join((await _coversDir()).path, '$id$ext');
            await File(coverTempPath).copy(coverTarget);
            coverPath = coverTarget;
          } catch (_) {}
        }

        final book = Book(
          id: id,
          title: title,
          author: author,
          filePath: target,
          format: BookFormat.epub,
          addedAt: now,
          coverPath: coverPath,
          sourceCatalogUrl: sourceCatalogUrl,
          sourceLastChapterId: sourceLastChapterId,
        );
        books.insert(0, book);
        _cache = List.of(books);
        await _persist(books);
        return book;
      });

  /// 合并更新一本书的统计字段（一次读写）。
  Future<void> updateBook(
    String id, {
    int addReadSeconds = 0,
    int? setWordCount,
    int? setLastReadAt,
    int? setSourceLastChapterId,
  }) =>
      _serialized(() async {
        final books = await _freshCopy();
        final idx = books.indexWhere((b) => b.id == id);
        if (idx < 0) return;
        final b = books[idx];
        books[idx] = b.copyWith(
          wordCount: setWordCount,
          readSeconds: b.readSeconds + addReadSeconds,
          lastReadAt: setLastReadAt,
          sourceLastChapterId: setSourceLastChapterId,
        );
        _cache = List.of(books);
        await _persist(books);
      });

  /// 只更新一本书的封面路径（用户自选封面覆盖）。
  Future<void> setCover(String id, String? coverPath) =>
      _serialized(() async {
        final books = await _freshCopy();
        final idx = books.indexWhere((b) => b.id == id);
        if (idx < 0) return;
        books[idx] = books[idx].copyWith(coverPath: coverPath);
        _cache = List.of(books);
        await _persist(books);
      });
}
