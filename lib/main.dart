import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/home_shell.dart';
import 'services/book_parser.dart';
import 'theme/app_colors.dart';

void main() {
  if (kDebugMode) _selfTest();
  runApp(const NovelReaderApp());
}

/// debug 启动自检：验证「写文件 → 读字节 → 解析」完整链路，
/// 结果打印到 logcat（flutter run 输出），供程序化验证打开书籍流程。
Future<void> _selfTest() async {
  try {
    final dir = await Directory.systemTemp.createTemp('novel_selftest');
    final file = File('${dir.path}${Platform.pathSeparator}test.txt');
    const content = '第一章 起点\n这是第一章的内容。\n\n第二章 转折\n'
        '这是第二章的内容。\n\n第三章 结局\n这是第三章的内容。\n';
    await file.writeAsString(content, flush: true);
    final bytes = await file.readAsBytes();
    final parsed = await parseBookFromBytes(
      Uint8List.fromList(bytes),
      'txt',
    );
    debugPrint('[selfTest] OK 章节数=${parsed.chapters.length} '
        '字数=${parsed.wordCount} '
        '首章=${parsed.chapters.first.title}');
    await _selfTestEpub();
  } catch (e, st) {
    debugPrint('[selfTest] FAIL $e\n$st');
  }
}

/// EPUB 用例：复刻「toc.ncx 缺 <head>」这一真实故障样本的结构，
/// 验证修复重试路径可用。
Future<void> _selfTestEpub() async {
  try {
    String add(Archive a, String name, String content) {
      final data = Uint8List.fromList(utf8.encode(content));
      a.addFile(ArchiveFile(name, data.length, data));
      return content;
    }

    final arch = Archive();
    add(arch, 'mimetype', 'application/epub+zip');
    add(arch, 'META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
    add(arch, 'OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试电子书</dc:title>
    <dc:creator>测试作者</dc:creator>
    <dc:identifier id="id">test-001</dc:identifier>
    <dc:language>zh</dc:language>
  </metadata>
  <manifest>
    <item id="c1" href="c1.html" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''');
    add(arch, 'OEBPS/c1.html', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c1</title></head>
<body><h1>第一章 起点</h1><p>这是自检正文。</p></body></html>''');
    // 注意：故意不含 <head> 以外的 ncx head 元素 —— 复刻故障。
    add(arch, 'OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap><navPoint id="n1" playOrder="1"><navLabel><text>第一章 起点</text></navLabel><content src="c1.html"/></navPoint></navMap>
</ncx>''');
    final bytes = Uint8List.fromList(ZipEncoder().encode(arch)!);
    final parsed = await parseBookFromBytes(bytes, 'epub');
    debugPrint('[selfTest][epub] OK 章节数=${parsed.chapters.length} '
        '标题=${parsed.title} 首段=${parsed.chapters.first.paragraphs.first}');
  } catch (e, st) {
    debugPrint('[selfTest][epub] FAIL $e\n$st');
  }
}

class NovelReaderApp extends StatelessWidget {
  const NovelReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: '小说阅读',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: AppColors.bg,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
        ),
      ),
      home: const HomeShell(),
    );
  }
}
