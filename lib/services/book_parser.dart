import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart';
import 'package:fast_gbk/fast_gbk.dart';

import '../models/book.dart';

/// 解析结果：正文章节 + 元信息。
class ParsedBook {
  final List<Chapter> chapters;
  final String title;
  final String author;
  final int wordCount; // 正文总字数（去空白字符）
  final Uint8List? coverBytes; // EPUB 内嵌封面原始字节（TXT 或无封面为 null）
  final String coverExt; // 封面扩展名，如 '.jpg' / '.png'

  ParsedBook({
    required this.chapters,
    required this.title,
    required this.author,
    required this.wordCount,
    this.coverBytes,
    this.coverExt = '',
  });
}

/// 解析一本书（TXT 或 EPUB）。
Future<ParsedBook> parseBook(Book book) async {
  // 检查文件路径是否为空
  if (book.filePath.isEmpty) {
    throw FormatException('文件路径为空，无法解析书籍《${book.title}》');
  }

  // 检查文件是否存在
  final file = File(book.filePath);
  if (!file.existsSync()) {
    throw FormatException('书籍文件不存在：${book.filePath}');
  }

  if (book.format == BookFormat.txt) {
    final bytes = await file.readAsBytes();
    final chapters = parseTxt(bytes);
    return ParsedBook(
      chapters: chapters,
      title: book.title,
      author: book.author,
      wordCount: _countWords(chapters),
    );
  }
  final bytes = await file.readAsBytes();
  return _parseEpub(bytes, fallbackTitle: book.title, fallbackAuthor: book.author);
}

/// 大书必须在后台 isolate 解析，否则主线程卡顿触发 ANR。
/// 用 compute(顶层函数, 记录消息)：跨 isolate 只传可发送的
/// 纯数据参数，不发送任何闭包，杜绝 object is unsendable。
Future<ParsedBook> parseBookMessage((Uint8List, String) args) {
  final (bytes, formatName) = args;
  return parseBookFromBytes(bytes, formatName);
}

/// 可跨 isolate 的纯数据解析入口：参数只有 Uint8List 和 String，
/// 供后台 isolate 使用（不含任何 UI 对象引用）。
Future<ParsedBook> parseBookFromBytes(Uint8List bytes, String formatName) async {
  final isEpub = formatName == BookFormat.epub.name;
  if (!isEpub) {
    final chapters = parseTxt(bytes);
    return ParsedBook(
      chapters: chapters,
      title: '',
      author: '',
      wordCount: _countWords(chapters),
    );
  }
  final parsed = await _parseEpub(bytes);
  return ParsedBook(
    chapters: parsed.chapters,
    title: '',
    author: '',
    wordCount: _countWords(parsed.chapters),
  );
}

/// 统计正文字数（只算段落文字，去空白字符，不含章节标题）。
int _countWords(List<Chapter> chapters) {
  var count = 0;
  for (final c in chapters) {
    for (final p in c.paragraphs) {
      count += p.replaceAll(RegExp(r'\s'), '').length;
    }
  }
  return count;
}

/// 解析 TXT：自动识别编码，按章节标题切分。
List<Chapter> parseTxt(Uint8List bytes) {
  final text = _decodeBytes(bytes);
  return _splitTxtChapters(text);
}

/// 编码自动识别：UTF-8 BOM / UTF-16 BOM / UTF-8 / GBK。
String _decodeBytes(Uint8List bytes) {
  // UTF-8 BOM
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  // UTF-16 BOM
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes, littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes, littleEndian: false);
    }
  }
  // 尝试 UTF-8，失败回退 GBK
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final data = ByteData.sublistView(bytes, 2);
  final count = data.lengthInBytes ~/ 2;
  final codeUnits = <int>[];
  for (var i = 0; i < count; i++) {
    codeUnits.add(data.getUint16(i * 2, littleEndian ? Endian.little : Endian.big));
  }
  return String.fromCharCodes(codeUnits);
}

/// 章节标题行匹配：第X章/回/节、序章、楔子、番外、后记等。
final RegExp _chapterHeading = RegExp(
  r'^\s*(第\s*[0-9零一二三四五六七八九十百千万两〇]+\s*[章回节卷集部篇].*'
  r'|序章.*|序言.*|楔子.*|前言.*|引子.*|后记.*|尾声.*|番外.*|终章.*)$',
);

List<Chapter> _splitTxtChapters(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = text.split('\n');

  final hasHeading = lines.any((l) => _chapterHeading.hasMatch(l));
  if (!hasHeading) {
    final paras =
        lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (paras.isEmpty) return [];
    return [Chapter(title: '', paragraphs: paras)];
  }

  final chapters = <Chapter>[];
  var title = '';
  var body = <String>[];

  void flush() {
    final paras =
        body.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (title.isNotEmpty || paras.isNotEmpty) {
      chapters.add(Chapter(title: title, paragraphs: paras));
    }
    title = '';
    body = [];
  }

  for (final line in lines) {
    if (_chapterHeading.hasMatch(line)) {
      flush();
      title = line.trim();
    } else {
      body.add(line);
    }
  }
  flush();

  return chapters;
}

Future<ParsedBook> _parseEpub(
  Uint8List bytes, {
  String fallbackTitle = '',
  String fallbackAuthor = '',
}) async {
  EpubBook epub;
  try {
    epub = await EpubReader.readBook(bytes);
  } catch (_) {
    // epubx 强制要求 toc.ncx 含 <head>，但很多生成器会省略导致
    // "TOC file does not contain head element"；修复后重试一次。
    epub = await EpubReader.readBook(_repairEpubForEpubx(bytes));
  }
  final chapters = <Chapter>[];

  for (final ch in epub.Chapters ?? const <EpubChapter>[]) {
    chapters.add(
      Chapter(
        title: (ch.Title ?? '').trim(),
        paragraphs: _htmlToParagraphs(ch.HtmlContent ?? ''),
      ),
    );
  }
  if (chapters.isEmpty) {
    chapters.add(Chapter(title: '', paragraphs: ['（无法解析该书内容）']));
  }

  // 提取内嵌封面（优先文件名含 cover 的图片，否则第一张）。
  Uint8List? coverBytes;
  String coverExt = '';
  final images = epub.Content?.Images;
  if (images != null && images.isNotEmpty) {
    String? coverKey;
    for (final key in images.keys) {
      if (key.toLowerCase().contains('cover')) {
        coverKey = key;
        break;
      }
    }
    coverKey ??= images.keys.first;
    final coverFile = images[coverKey]!;
    final raw = coverFile.Content;
    if (raw != null && raw.isNotEmpty) {
      coverBytes = Uint8List.fromList(raw);
      final mime = (coverFile.ContentMimeType ?? '').toLowerCase();
      coverExt = mime.contains('png')
          ? '.png'
          : mime.contains('gif')
              ? '.gif'
              : '.jpg';
    }
  }

  final title = (epub.Title ?? '').trim();
  final author = (epub.Author ?? '').trim();
  return ParsedBook(
    chapters: chapters,
    title: title.isNotEmpty ? title : fallbackTitle,
    author: author.isNotEmpty ? author : fallbackAuthor,
    wordCount: _countWords(chapters),
    coverBytes: coverBytes,
    coverExt: coverExt,
  );
}

/// epubx 解析 EPUB2 的 toc.ncx 时强制要求存在 <head> 与直接子级
/// <docTitle> 元素，但很多生成器会省略它们；解包 zip 把缺失的
/// 元素注入 ncx 开标签之后，再重新打包。无改动时原样返回。
Uint8List _repairEpubForEpubx(Uint8List bytes) {
  final Archive src;
  try {
    src = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return bytes;
  }
  var changed = false;
  final out = Archive();
  for (final file in src.files) {
    var data = file.content;
    if (file.name.toLowerCase().endsWith('.ncx') && data.isNotEmpty) {
      try {
        final text = utf8.decode(data);
        final hasHead =
            RegExp(r'<\s*head[\s>/]', caseSensitive: false).hasMatch(text);
        final hasDocTitle = RegExp(r'<\s*docTitle[\s>/]', caseSensitive: false)
            .hasMatch(text);
        if ((!hasHead || !hasDocTitle)) {
          var injection = '';
          if (!hasHead) injection += '<head/>';
          if (!hasDocTitle) injection += '<docTitle><text> </text></docTitle>';
          final fixed = text.replaceFirstMapped(
            RegExp(r'(<\s*ncx\b[^>]*>)', caseSensitive: false),
            (m) => '${m[1]}$injection',
          );
          if (fixed != text) {
            data = Uint8List.fromList(utf8.encode(fixed));
            changed = true;
          }
        }
      } catch (_) {}
    }
    out.addFile(ArchiveFile(file.name, data.length, data));
  }
  if (!changed) return bytes;
  return Uint8List.fromList(ZipEncoder().encode(out)!);
}

/// 把 XHTML 片段转成纯文本段落列表。
List<String> _htmlToParagraphs(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<\s*br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*p\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*div\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*h[1-6]\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*li\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*tr\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*/\s*blockquote\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<\s*[^>]*>'), '');

  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&ldquo;', '“')
      .replaceAll('&rdquo;', '”')
      .replaceAll('&lsquo;', '‘')
      .replaceAll('&rsquo;', '’')
      .replaceAll('&hellip;', '…')
      .replaceAll('&mdash;', '—')
      .replaceAll('&middot;', '·');

  return s
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}
