import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 下载章节：标题 + 正文段落。
class EpubChapter {
  final String title;
  final List<String> paragraphs;

  EpubChapter({required this.title, required this.paragraphs});
}

/// 把章节列表构建成 EPUB2 文件（zip 字节流）。
///
/// 结构：mimetype（STORED、置于首个）+ META-INF/container.xml
///      + OEBPS/content.opf + toc.ncx + cover.xhtml + chapterN.xhtml + style.css
class EpubBuilder {
  static const _css = '''
body { line-height: 1.8; margin: 0 5%; }
h1 { text-align: center; font-size: 1.4em; font-weight: bold; margin: 1em 0 1.2em; }
p { text-indent: 2em; margin: 0.4em 0; }''';

  static Uint8List build({
    required String title,
    required String author,
    required List<EpubChapter> chapters,
  }) {
    final archive = Archive();

    // 1. mimetype 必须是第一个 entry 且不压缩（STORED）。
    final mimetype = Uint8List.fromList(utf8.encode('application/epub+zip'));
    archive.addFile(
        ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));

    // 2. container.xml
    archive.addFile(ArchiveFile.string(
        'META-INF/container.xml', _containerXml()));

    // 3. 样式表
    archive.addFile(ArchiveFile.string('OEBPS/style.css', _css));

    // 4. 封面页（文字封面）
    archive.addFile(ArchiveFile.string(
        'OEBPS/cover.xhtml', _coverXhtml(title, author)));

    // 5. 章节
    for (var i = 0; i < chapters.length; i++) {
      final fname = 'OEBPS/chapter${i + 1}.xhtml';
      archive.addFile(ArchiveFile.string(
          fname, _chapterXhtml(chapters[i].title, chapters[i].paragraphs)));
    }

    final bookId = 'urn:uuid:${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';

    // 6. content.opf
    archive.addFile(ArchiveFile.string(
        'OEBPS/content.opf', _opf(title, author, bookId, chapters.length)));

    // 7. toc.ncx
    archive.addFile(ArchiveFile.string(
        'OEBPS/toc.ncx', _ncx(title, bookId, chapters)));

    final bytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(bytes ?? const <int>[]);
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _containerXml() => '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  static String _coverXhtml(String title, String author) => '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>封面</title></head>
<body style="margin:0;padding:0;text-align:center;">
<div style="padding-top:45%;"></div>
<div style="font-size:2.2em;font-weight:bold;color:#222;">${_esc(title)}</div>
<div style="margin-top:1.5em;font-size:1.1em;color:#555;">${_esc(author.isEmpty ? '佚名' : author)} 著</div>
</body>
</html>''';

  static String _chapterXhtml(String title, List<String> paragraphs) {
    final t = _esc(title.isEmpty ? '正文' : title);
    final ps = paragraphs
        .map((p) => '<p>${_esc(p)}</p>')
        .join('\n');
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>$t</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
<h1>$t</h1>
$ps
</body>
</html>''';
  }

  static String _opf(
      String title, String author, String bookId, int chapterCount) {
    final manifest = StringBuffer();
    manifest.writeln('    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>');
    manifest.writeln('    <item id="css" href="style.css" media-type="text/css"/>');
    for (var i = 1; i <= chapterCount; i++) {
      manifest.writeln(
          '    <item id="chap$i" href="chapter$i.xhtml" media-type="application/xhtml+xml"/>');
    }
    manifest.writeln('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');

    final spine = StringBuffer();
    spine.writeln('    <itemref idref="cover"/>');
    for (var i = 1; i <= chapterCount; i++) {
      spine.writeln('    <itemref idref="chap$i"/>');
    }

    return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>${_esc(title)}</dc:title>
    <dc:creator>${_esc(author.isEmpty ? '佚名' : author)}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:identifier id="bookid">$bookId</dc:identifier>
  </metadata>
  <manifest>
${manifest.toString()}  </manifest>
  <spine toc="ncx">
${spine.toString()}  </spine>
</package>''';
  }

  static String _ncx(String title, String bookId, List<EpubChapter> chapters) {
    final navMap = StringBuffer();
    for (var i = 0; i < chapters.length; i++) {
      final t = _esc(chapters[i].title.isEmpty ? '第 ${i + 1} 章' : chapters[i].title);
      navMap.writeln('    <navPoint id="chap${i + 1}" playOrder="${i + 1}">');
      navMap.writeln('      <navLabel><text>$t</text></navLabel>');
      navMap.writeln('      <content src="chapter${i + 1}.xhtml"/>');
      navMap.writeln('    </navPoint>');
    }
    return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="$bookId"/></head>
  <docTitle><text>${_esc(title)}</text></docTitle>
  <navMap>
${navMap.toString()}  </navMap>
</ncx>''';
  }
}
