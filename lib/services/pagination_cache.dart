import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pagination.dart';

/// 分页结果磁盘缓存：键 = 排版参数 + 窗口尺寸。同一排版只全书计算
/// 一次，之后打开直接载入（毫秒级）；字号/行距/字体变了才重算。
class PaginationCache {
  PaginationCache._();

  static Future<String> _pathFor(String key) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'cache', 'pages'));
    if (!await dir.exists()) await dir.create(recursive: true);
    // 文件名里只留安全字符，其余替换成下划线。
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return p.join(dir.path, '$safe.json');
  }

  static Future<PaginateResult?> load(String key) async {
    try {
      final f = File(await _pathFor(key));
      if (!await f.exists()) return null;
      final map = json.decode(await f.readAsString()) as Map<String, dynamic>;
      return PaginateResult(
        (map['s'] as List<dynamic>).cast<int>(),
        (map['c'] as List<dynamic>).cast<int>(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String key, PaginateResult r) async {
    try {
      await File(await _pathFor(key)).writeAsString(
        json.encode({'s': r.starts, 'c': r.chars}),
      );
    } catch (_) {}
  }

  /// 删除某本书的全部分页缓存（键以书 id 开头，删书时调用）。
  static Future<void> removeBook(String bookId) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'cache', 'pages'));
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is File && p.basename(e.path).startsWith(bookId)) {
          await e.delete();
        }
      }
    } catch (_) {}
  }
}
