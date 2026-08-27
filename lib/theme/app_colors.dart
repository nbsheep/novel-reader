import 'package:flutter/material.dart';

/// 全局深色紫调配色（对齐 test.html 的概念设计）。
class AppColors {
  AppColors._();

  // 页面背景
  static const Color bg = Color(0xFF0B0B10);
  static const Color bgElevated = Color(0xFF0F0F16);

  // 卡片
  static const Color surface = Color(0xFF181821);
  static const Color surfaceAlt = Color(0xFF1A1A26);

  // 强调色（紫色）
  static const Color accent = Color(0xFFA78BFA);
  static const Color accentLight = Color(0xFFC4B0FF);
  static const Color accentBright = Color(0xFFD9CAFF);
  static const Color accentMid = Color(0xFFB294F0);

  /// 主渐变（标题、进度条、强调数字）。
  static const List<Color> gradient = [accentBright, accentMid];

  // 文字
  static const Color textPrimary = Color(0xFFEDEDF5);
  static const Color textSecondary = Color(0xFF6A6A7E);

  // 边框
  static const Color border = Color(0xFF26263A);
}
