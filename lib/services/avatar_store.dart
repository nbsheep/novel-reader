import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户头像：字节写文档目录 avatar.jpg，路径存 SharedPreferences。
class AvatarStore {
  AvatarStore._();

  static const _key = 'avatar_path';

  /// 写入头像字节，返回本地路径；失败返回 null。
  static Future<String?> saveAvatar(List<int> bytes) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(p.join(docs.path, 'avatar.jpg'));
      await file.writeAsBytes(bytes, flush: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, file.path);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 读取当前头像路径；未设置或文件已丢失返回 null。
  static Future<String?> getAvatarPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_key);
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    return path;
  }

  /// 移除头像（删文件 + 清路径）。
  static Future<void> clearAvatar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_key);
      if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
      await prefs.remove(_key);
    } catch (_) {}
  }
}
