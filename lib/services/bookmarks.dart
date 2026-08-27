import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条书签：记录阅读器内的区块位置，便于一键跳回。
class Bookmark {
  final int blockIndex; // 阅读器区块下标（章节标题块也算，见 reader_screen 的 _locate）
  final int chapterIndex; // 章节下标
  final String chapterTitle; // 章节标题（空则显示「第 X 章」）
  final String snippet; // 段落文字前若干字（可为空）
  final int createdAt; // millisecondsSinceEpoch

  Bookmark({
    required this.blockIndex,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'blockIndex': blockIndex,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'snippet': snippet,
        'createdAt': createdAt,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        blockIndex: json['blockIndex'] as int? ?? 0,
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
        createdAt: json['createdAt'] as int? ?? 0,
      );
}

/// 按书持久化书签，存 SharedPreferences 的 `bookmarks_{bookId}`（JSON 数组）。
class BookmarkStore {
  static String _key(String bookId) => 'bookmarks_$bookId';

  static Future<List<Bookmark>> load(String bookId) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key(bookId));
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String bookId, List<Bookmark> bookmarks) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _key(bookId),
      json.encode(bookmarks.map((b) => b.toJson()).toList()),
    );
  }

  static Future<void> clear(String bookId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key(bookId));
  }
}
