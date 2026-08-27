/// 一个章节：标题 + 若干正文段落。
class Chapter {
  final String title;
  final List<String> paragraphs;

  Chapter({required this.title, required this.paragraphs});

  Map<String, dynamic> toJson() => {
        'title': title,
        'paragraphs': paragraphs,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        title: json['title'] as String? ?? '',
        paragraphs: (json['paragraphs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 书籍格式。
enum BookFormat { txt, epub }

/// 一本书的元信息（正文不常驻内存，打开时按需解析）。
class Book {
  final String id;
  final String title;
  final String author;
  final String filePath;
  final BookFormat format;
  final int addedAt; // millisecondsSinceEpoch
  final int wordCount; // 总字数（0 表示未计算）
  final int readSeconds; // 累计阅读秒数
  final int lastReadAt; // 最近打开时间戳，0 表示未读过
  final String? coverPath; // 本地封面图路径（无封面为 null）

  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.filePath,
    required this.format,
    required this.addedAt,
    this.wordCount = 0,
    this.readSeconds = 0,
    this.lastReadAt = 0,
    this.coverPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'filePath': filePath,
        'format': format.name,
        'addedAt': addedAt,
        'wordCount': wordCount,
        'readSeconds': readSeconds,
        'lastReadAt': lastReadAt,
        'coverPath': coverPath,
      };

  factory Book.fromJson(Map<String, dynamic> json) {
    final filePath = json['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) {
      throw FormatException('文件路径为空，无法解析书籍信息');
    }
    return Book(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        filePath: filePath,
        format: BookFormat.values.firstWhere(
          (f) => f.name == json['format'],
          orElse: () => BookFormat.txt,
        ),
        addedAt: json['addedAt'] as int? ?? 0,
        wordCount: json['wordCount'] as int? ?? 0,
        readSeconds: json['readSeconds'] as int? ?? 0,
        lastReadAt: json['lastReadAt'] as int? ?? 0,
        coverPath: json['coverPath'] as String?,
      );
  }
}
