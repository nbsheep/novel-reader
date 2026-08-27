import 'package:flutter/material.dart';

/// 一套阅读配色：背景色 + 正文色 + 次要文字色。
class ReadingTheme {
  final String name;
  final Color background;
  final Color text;
  final Color secondaryText;
  final bool isDark;

  const ReadingTheme({
    required this.name,
    required this.background,
    required this.text,
    required this.secondaryText,
    this.isDark = false,
  });
}

/// 可切换的背景配色，顺序即书架选择顺序。
const List<ReadingTheme> readingThemes = [
  ReadingTheme(
    name: '纯白',
    background: Color(0xFFFFFFFF),
    text: Color(0xFF333333),
    secondaryText: Color(0xFF9A9A9A),
  ),
  ReadingTheme(
    name: '米黄',
    background: Color(0xFFF5E3C3),
    text: Color(0xFF3F3A2F),
    secondaryText: Color(0xFFA89B7A),
  ),
  ReadingTheme(
    name: '羊皮纸',
    background: Color(0xFFF0E6D2),
    text: Color(0xFF4A3F2B),
    secondaryText: Color(0xFFB0A38A),
  ),
  ReadingTheme(
    name: '护眼绿',
    background: Color(0xFFCBE8C6),
    text: Color(0xFF2E3B2E),
    secondaryText: Color(0xFF7A9A7A),
  ),
  ReadingTheme(
    name: '淡粉',
    background: Color(0xFFF6E3E3),
    text: Color(0xFF4A2F2F),
    secondaryText: Color(0xFFB08989),
  ),
  ReadingTheme(
    name: '淡蓝',
    background: Color(0xFFDDE9F5),
    text: Color(0xFF2A3846),
    secondaryText: Color(0xFF8AA0B5),
  ),
  ReadingTheme(
    name: '灰色',
    background: Color(0xFFE6E6E6),
    text: Color(0xFF333333),
    secondaryText: Color(0xFF9A9A9A),
  ),
  ReadingTheme(
    name: '夜间',
    background: Color(0xFF0F0F16),
    text: Color(0xFFC9C9D4),
    secondaryText: Color(0xFF6A6A7E),
    isDark: true,
  ),
];
