import 'dart:async';
import 'dart:ui' show runOnPlatformThread;

import 'package:flutter/material.dart';

import '../models/book.dart';

/// 分页入参：纯数据，可跨 isolate 发送。
class PaginationArgs {
  final List<Chapter> chapters;
  final List<int> chapterStarts;
  final int totalBlocks;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final double width;
  final double height;

  const PaginationArgs({
    required this.chapters,
    required this.chapterStarts,
    required this.totalBlocks,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.width,
    required this.height,
  });
}

/// 分页结果。
///
/// [starts][k] 与 [chars][k] 共同描述第 k 页的起点游标 (块下标, 块内字符偏移)：
/// 一般情况 chars 为 0；某块段落本身比一页还高时会被切开，后续页复用同一
/// 块下标并带非零字符偏移（相当于"从本段第 N 个字开始"）。
/// 渲染覆盖区间为 [(starts[k],chars[k]), (starts[k+1],chars[k+1]))，
/// 哨兵项为 (totalBlocks, 0)。
class PaginateResult {
  final List<int> starts;
  final List<int> chars;
  const PaginateResult(this.starts, this.chars);
}

/// 同步入口（消息里只有可发送的纯数据）。全书 TextPainter 测量只能
/// 在有文本能力的线程做：普通后台 isolate 会报
/// "UI actions are only available on root isolate"，主线程整书算则卡帧。
PaginateResult paginateMessage(PaginationArgs a) {
  if (a.totalBlocks <= 0) return const PaginateResult([0], [0]);
  final pager = _Pager(a);
  while (!pager.done) {
    pager.stepBlock();
  }
  return pager.result;
}

/// 异步大书分页：
/// 1) 优先派给平台线程 isolate（runOnPlatformThread，带文本能力），
///    主线程全程不参与测量；
/// 2) 平台不支持该能力时抛错，自动回退主 isolate 时间片分块——
///    每片限时约 6ms 就让出事件循环，期间进度动画照常播放，
///    任何单帧都不会被测量阻塞太久，杜绝 ANR。
Future<PaginateResult> paginateAsync(PaginationArgs a) async {
  if (a.totalBlocks <= 0) return const PaginateResult([0], [0]);
  final sw = Stopwatch()..start();
  try {
    final r = await runOnPlatformThread(() => paginateMessage(a));
    debugPrint('[分页] 路径=平台线程 耗时=${sw.elapsedMilliseconds}ms');
    return r;
  } catch (e) {
    debugPrint('[分页] 平台线程不可用($e)，回退主线程分片');
  }
  final r = await _paginateInChunks(a);
  debugPrint('[分页] 路径=主线程分片 耗时=${sw.elapsedMilliseconds}ms');
  return r;
}

const int _sliceBudgetUs = 6000;

Future<PaginateResult> _paginateInChunks(PaginationArgs a) async {
  final pager = _Pager(a);
  final sw = Stopwatch();
  while (!pager.done) {
    sw
      ..reset()
      ..start();
    while (!pager.done && sw.elapsedMicroseconds < _sliceBudgetUs) {
      pager.stepBlock();
    }
    sw.stop();
    await Future<void>.delayed(Duration.zero);
  }
  return pager.result;
}

/// 分页内核：把 block 序列按当前排版设置切成固定高度的页。
///
/// 与 reader 的 block 索引（`_chapterStarts`/`_totalBlocks`/`_locate`）保持
/// 一致——分页只是给「哪些内容落在同一页」加了一层映射，进度/书签/统计
/// 仍以 block 下标为唯一真源。超过整页高度的段落按二分测宽切成多页，
/// 页边界用字符偏移表达，渲染端按同样的游标切片。
class _Pager {
  _Pager(PaginationArgs a)
      : chapters = a.chapters,
        chapterStarts = a.chapterStarts,
        totalBlocks = a.totalBlocks,
        contentWidth = a.width - 40, // 左右 padding 20
        contentHeight = a.height - 2, // 留 2px 缓冲防 Column 溢出
        textStyle = TextStyle(
          fontSize: a.fontSize,
          height: a.lineHeight,
          fontFamily: a.fontFamily == 'default' ? null : a.fontFamily,
        ) {
    titleStyle = textStyle.copyWith(
      fontSize: a.fontSize + 5,
      fontWeight: FontWeight.w700,
      height: 1.4,
    );
  }

  static const _minSliceChars = 8;

  late final double _bodyLineStep = textStyle.fontSize! * textStyle.height!;
  late final double _titleLineStep = titleStyle.fontSize! * titleStyle.height!;

  /// TextPainter 的总高度与真实排版的 RenderBox 存在逐行取整的累计差
  /// （实测最高 ~1.8px/行）。按每行 2.5px + 底数 6px 做保守补偿，
  /// 保证任何页的渲染高度都不超过预算；代价只是页尾多留少量空白。
  double _rounded(double rawHeight, double lineStep) {
    final lines = (rawHeight / lineStep).ceil();
    return rawHeight + lines * 2.5 + 6;
  }

  final List<Chapter> chapters;
  final List<int> chapterStarts;
  final int totalBlocks;
  final double contentWidth;
  final double contentHeight;
  final TextStyle textStyle;
  late final TextStyle titleStyle;
  final TextDirection dir = TextDirection.ltr;

  final List<int> pageStarts = <int>[0];
  final List<int> pageChars = <int>[0];
  double _currentY = 0;
  int _index = 0;

  bool get done => _index >= totalBlocks;

  PaginateResult get result => PaginateResult(
        [...pageStarts, totalBlocks],
        [...pageChars, 0],
      );

  int _locateChapter(int index) {
    var lo = 0;
    var hi = chapterStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (chapterStarts[mid] <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void _breakHere(int charOffset) {
    pageStarts.add(_index);
    pageChars.add(charOffset);
    _currentY = 0;
  }

  /// 处理一个 block；段落超长时内部会连续开出多页。
  void stepBlock() {
    final chapter = _locateChapter(_index);
    final ch = chapters[chapter];
    final para = _index - chapterStarts[chapter] - 1;

    if (para < 0) {
      // 空标题块渲染为零高度，与 reader 的 SizedBox.shrink 对齐。
      final h = ch.title.isEmpty ? 0 : _measureTitle(ch.title);
      if (h > 0) {
        if (_currentY > 0 && _currentY + h > contentHeight) _breakHere(0);
        _currentY += h;
      }
      _index++;
      return;
    }

    final raw = ch.paragraphs[para];
    var off = 0;
    while (off < raw.length) {
      // 与渲染一致：仅段首加全角缩进。
      final base = off == 0 ? '　　' : '';
      final segText = '$base${raw.substring(off)}';
      final h = _measurePara(segText);
      final maxTake = raw.length - off;

      // 剩余空间装得下（或本就是空页且整体能放下）：放完收工。
      if (h <= contentHeight &&
          (_currentY == 0 || _currentY + h <= contentHeight)) {
        _currentY += h;
        break;
      }
      // 当前页还有残留内容：先换新页再试。
      if (_currentY > 0) {
        _breakHere(off);
        continue;
      }
      // 空页也放不下：整段超页，二分找恰好铺满一页的字符数（不含缩进）。
      var lo = _minSliceChars;
      var hi = maxTake;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        final mh =
            _measurePara('$base${raw.substring(off, off + mid)}');
        if (mh <= contentHeight) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      _currentY +=
          _measurePara('$base${raw.substring(off, off + lo)}');
      off += lo;
      if (off < raw.length) _breakHere(off);
    }
    _index++;
  }

  /// 测量值必须含渲染端的 Padding（正文下 14；标题上 28 下 16）与
  /// 逐行取整补偿，否则每页会被实际渲染撑出溢出。
  double _measureTitle(String title) {
    final tp = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: dir,
      textAlign: TextAlign.center,
    )..layout(maxWidth: contentWidth);
    final h = _rounded(tp.height, _titleLineStep) + 28 + 16;
    tp.dispose();
    return h;
  }

  double _measurePara(String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: dir,
      textAlign: TextAlign.justify,
    )..layout(maxWidth: contentWidth);
    final h = _rounded(tp.height, _bodyLineStep) + 14;
    tp.dispose();
    return h;
  }
}

/// 翻页模式下 block 下标 → 所在页（在 pageStarts 上二分）。
/// 同一段落被切成的多页会共享相同起点，取最后一页（该段的更靠后位置）。
class Pagination {
  Pagination._();

  static int pageOf(List<int> pageStarts, int index) {
    if (pageStarts.length <= 1) return 0;
    var lo = 0;
    var hi = pageStarts.length - 2; // 最后一页的起始下标
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (pageStarts[mid] <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
