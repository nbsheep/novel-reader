import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import 'book_library.dart';
import 'book_parser.dart';
import 'epub_builder.dart';
import 'guishuji_source.dart';
import 'parse_cache.dart';

/// 在线书的章节更新：增量抓新章 → 与旧章节合并重建 EPUB（原路径覆盖）。
/// 新章节追加在末尾，旧章节块下标不变，阅读进度/书签不受影响。
class BookUpdater {
  /// 返回新增章节数。[onProgress] 上报新章节抓取进度。
  static Future<int> updateBook(
    Book book,
    CatalogInfo info, {
    required void Function(int done, int total) onProgress,
  }) async {
    final after = book.sourceLastChapterId ?? info.firstId - 1;
    if (info.lastId <= after) return 0;

    final src = File(book.filePath);
    if (!await src.exists()) {
      throw const FormatException('书籍文件不存在');
    }

    // 旧章节：优先解析缓存（毫秒级），未命中才整本解析。
    final stat = await src.stat();
    final cachePath = await ParseCache.pathFor(book.id);
    final cached = await compute(
      ParseCache.load,
      (cachePath, book.filePath, stat.size, stat.modified.millisecondsSinceEpoch),
    );
    final List<Chapter> oldChapters;
    if (cached != null) {
      oldChapters = cached.chapters;
    } else {
      final bytes = await src.readAsBytes();
      final parsed = await compute(
          parseBookMessage, (bytes, book.format.name));
      oldChapters = parsed.chapters;
    }

    final newChapters = await GuishujiSource.fetchNewChapters(
      info,
      after,
      onProgress: onProgress,
    );
    if (newChapters.isEmpty) return 0;

    final all = <EpubChapter>[
      for (final c in oldChapters)
        EpubChapter(title: c.title, paragraphs: c.paragraphs),
      ...newChapters,
    ];
    final bytes2 = EpubBuilder.build(
      title: book.title,
      author: book.author,
      chapters: all,
    );
    await src.writeAsBytes(bytes2, flush: true);

    var wordCount = 0;
    for (final c in all) {
      for (final para in c.paragraphs) {
        wordCount += para.length;
      }
    }
    await BookLibrary().updateBook(
      book.id,
      setWordCount: wordCount,
      setSourceLastChapterId: info.lastId,
    );
    return newChapters.length;
  }
}
