import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import 'book_parser.dart';

/// 解析结果磁盘缓存：同一本书只在首次打开时真正解析，之后直接
/// 反序列化（数秒级 → 亚秒级）。编解码全部在后台 isolate，主线程
/// 只做取路径和传参。
class ParseCache {
  ParseCache._();

  static const _version = 1;

  /// 缓存文件路径（不保证存在）。
  static Future<String> pathFor(String bookId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return p.join(dir.path, 'parse_v$_version\_$bookId.json');
  }

  /// 后台 isolate 入口：读缓存并校验源文件未变化；null = 未命中。
  static Future<ParsedBook?> load(
    (String, String, int, int) args,
  ) async {
    final (cachePath, srcPath, srcSize, srcMtime) = args;
    try {
      final f = File(cachePath);
      if (!await f.exists()) return null;
      final src = File(srcPath);
      if (!await src.exists()) return null;
      final map = json.decode(await f.readAsString()) as Map<String, dynamic>;
      if (map['size'] != srcSize || map['mtime'] != srcMtime) return null;
      final chapters = <Chapter>[
        for (final e in map['chapters'] as List<dynamic>)
          Chapter(
            title: e[0] as String,
            paragraphs: (e[1] as List<dynamic>).cast<String>(),
          ),
      ];
      return ParsedBook(
        chapters: chapters,
        title: '',
        author: '',
        wordCount: map['wordCount'] as int,
      );
    } catch (e) {
      debugPrint('解析缓存读取失败: $e');
      return null;
    }
  }

  /// 后台 isolate 入口：编码并落盘。失败静默——缓存非关键路径。
  static Future<void> save(
    (String, int, int, List<Chapter>, int) args,
  ) async {
    final (cachePath, srcSize, srcMtime, chapters, wordCount) = args;
    try {
      await File(cachePath).writeAsString(json.encode({
        'size': srcSize,
        'mtime': srcMtime,
        'wordCount': wordCount,
        'chapters': [
          for (final c in chapters) [c.title, c.paragraphs],
        ],
      }));
    } catch (_) {}
  }

  /// 删除一本书的解析缓存（删书时调用）。
  static Future<void> deleteFor(String bookId) async {
    try {
      final f = File(await pathFor(bookId));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
