import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 自定义字体：导入的字体文件固定拷到 documents/fonts/custom_font.ttf，
/// 以 fontFamily 'custom_font' 注册，TextStyle 直接引用该名字。
class CustomFont {
  CustomFont._();

  static const family = 'custom_font';
  static const _pathKey = 'custom_font_path';
  static bool _loaded = false;

  /// 拷贝导入的字体文件到应用目录（覆盖旧字体），返回落盘路径。
  static Future<String> copyImported(String srcPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'fonts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = p.join(dir.path, 'custom_font.ttf');
    await File(srcPath).copy(target);
    _loaded = false; // 新文件需要重新注册
    return target;
  }

  static Future<String?> storedPath() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_pathKey);
  }

  static Future<void> _setStoredPath(String? path) async {
    final sp = await SharedPreferences.getInstance();
    if (path == null) {
      await sp.remove(_pathKey);
    } else {
      await sp.setString(_pathKey, path);
    }
  }

  /// 记录落盘字体路径（导入成功后调用）。
  static Future<void> register(String storedPath) => _setStoredPath(storedPath);

  /// 注册自定义字体到引擎（幂等）。没有导入过字体或加载失败返回 false。
  static Future<bool> ensureLoaded() async {
    if (_loaded) return true;
    try {
      final path = await storedPath();
      if (path == null || !await File(path).exists()) return false;
      final data = await File(path).readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(ByteData.view(data.buffer)));
      await loader.load();
      _loaded = true;
      return true;
    } catch (_) {
      return false;
    }
  }
}
