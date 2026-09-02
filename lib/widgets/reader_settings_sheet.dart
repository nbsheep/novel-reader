import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/reading_themes.dart';

/// 翻页方式。
enum PageTurnMode { scroll, slide, simulation, cover }

/// 翻页方式的中文标签。
String pageTurnLabel(PageTurnMode m) => switch (m) {
      PageTurnMode.scroll => '上下滚动',
      PageTurnMode.slide => '平移',
      PageTurnMode.simulation => '仿真',
      PageTurnMode.cover => '覆盖',
    };

/// 阅读设置（由面板返回给阅读页）。
class ReaderSettings {
  final double fontSize;
  final double lineHeight;
  final int themeIndex;
  final String fontFamily;
  final bool volumePageTurn;
  final double brightness;
  final PageTurnMode pageTurnMode;

  const ReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    required this.themeIndex,
    required this.fontFamily,
    this.volumePageTurn = false,
    this.brightness = 1.0,
    this.pageTurnMode = PageTurnMode.scroll,
  });
}

/// 阅读面板：点屏幕中央呼出。集成进度跳转、目录/书签/自动阅读入口
/// 与全部排版设置，面板随阅读主题配色，所有调整实时生效（防抖落盘
/// 由阅读页负责）。
class ReaderPanelSheet extends StatefulWidget {
  final double fontSize;
  final double lineHeight;
  final int themeIndex;
  final String fontFamily;
  final bool volumePageTurn;
  final double brightness;
  final PageTurnMode pageTurnMode;
  final ValueChanged<ReaderSettings> onChanged;

  final int currentChapter;
  final int totalChapters;
  final List<String> chapterTitles;
  final double progressRatio; // 全书 0..1（按块）
  final ValueChanged<int> onSeekChapter; // 进度条拖动跳章
  final bool autoScrolling;
  final bool bookmarked; // 当前章是否已有书签
  final VoidCallback onToggleBookmark;
  final VoidCallback onOpenChapters;
  final VoidCallback onOpenBookmarks;
  final VoidCallback onToggleAuto;
  final VoidCallback onToggleTts;
  final VoidCallback onImportFont;
  final int lastLightTheme; // 夜间 → 日间 时切回的主题

  const ReaderPanelSheet({
    super.key,
    required this.fontSize,
    required this.lineHeight,
    required this.themeIndex,
    required this.fontFamily,
    this.volumePageTurn = false,
    this.brightness = 1.0,
    this.pageTurnMode = PageTurnMode.scroll,
    required this.onChanged,
    required this.currentChapter,
    required this.totalChapters,
    required this.chapterTitles,
    required this.progressRatio,
    required this.onSeekChapter,
    this.autoScrolling = false,
    this.bookmarked = false,
    required this.onToggleBookmark,
    required this.onOpenChapters,
    required this.onOpenBookmarks,
    required this.onToggleAuto,
    required this.onToggleTts,
    required this.onImportFont,
    this.lastLightTheme = 0,
  });

  @override
  State<ReaderPanelSheet> createState() => _ReaderPanelSheetState();
}

class _ReaderPanelSheetState extends State<ReaderPanelSheet> {
  late double _fontSize;
  late double _lineHeight;
  late int _themeIndex;
  late String _fontFamily;
  late bool _volumePageTurn;
  late double _brightness;
  late PageTurnMode _pageTurnMode;
  late bool _bookmarked;
  late int _lastLight;
  bool _seeking = false;
  int _seekChapter = 0;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    _lineHeight = widget.lineHeight;
    _themeIndex = widget.themeIndex;
    _fontFamily = widget.fontFamily;
    _volumePageTurn = widget.volumePageTurn;
    _brightness = widget.brightness;
    _pageTurnMode = widget.pageTurnMode;
    _bookmarked = widget.bookmarked;
    _lastLight = widget.lastLightTheme == 7 ? 0 : widget.lastLightTheme;
    _seekChapter = widget.currentChapter;
  }

  void _notify() {
    widget.onChanged(ReaderSettings(
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      themeIndex: _themeIndex,
      fontFamily: _fontFamily,
      volumePageTurn: _volumePageTurn,
      brightness: _brightness,
      pageTurnMode: _pageTurnMode,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = readingThemes[_themeIndex];
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // 面板占屏幕约 2/3，上方正文实时预览调整效果；设置项内部可滚动。
    return Container(
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: theme.secondaryText.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          _buildHeader(theme),
          Divider(height: 1, color: theme.secondaryText.withValues(alpha: 0.2)),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildProgressSection(theme),
                  _sectionTitle('背景颜色', theme),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: List.generate(readingThemes.length, (i) {
                      final t = readingThemes[i];
                      final selected = i == _themeIndex;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _themeIndex = i;
                            if (i != 7) _lastLight = i;
                          });
                          _notify();
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: t.background,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? AppColors.accent
                                  : theme.secondaryText.withValues(alpha: 0.4),
                              width: selected ? 3 : 1,
                            ),
                          ),
                          child: selected
                              ? Icon(Icons.check,
                                  size: 20,
                                  color:
                                      t.isDark ? Colors.white : Colors.black87)
                              : null,
                        ),
                      );
                    }),
                  ),
                  _sectionTitle('亮度', theme),
                  _sliderRow(
                    theme: theme,
                    min: 0.3,
                    max: 1.0,
                    value: _brightness,
                    label: '${(_brightness * 100).round()}%',
                    onChanged: (v) {
                      setState(() => _brightness = v);
                      _notify();
                    },
                  ),
                  _sectionTitle('字号', theme),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.remove_circle_outline,
                            color: theme.secondaryText),
                        onPressed: () => _setFont(_fontSize - 1),
                      ),
                      Expanded(
                        child: _sliderRow(
                          theme: theme,
                          min: 12,
                          max: 32,
                          value: _fontSize,
                          label: _fontSize.round().toString(),
                          onChanged: (v) {
                            setState(() => _fontSize = v);
                            _notify();
                          },
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline,
                            color: theme.secondaryText),
                        onPressed: () => _setFont(_fontSize + 1),
                      ),
                    ],
                  ),
                  _sectionTitle('行距', theme),
                  _sliderRow(
                    theme: theme,
                    min: 1.2,
                    max: 2.6,
                    value: _lineHeight,
                    label: _lineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() => _lineHeight = v);
                      _notify();
                    },
                  ),
                  _sectionTitle('字体', theme),
                  Row(
                    children: [
                      _fontChoice('默认', 'default', theme),
                      _fontChoice('衬线', 'serif', theme),
                      _fontChoice('等宽', 'monospace', theme),
                      _fontChoice('自定义', 'custom_font', theme),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onImportFont,
                      child: Text(
                        '导入自定义字体（.ttf / .otf）',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.accentLight,
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '音量键翻页',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.text,
                      ),
                    ),
                    subtitle: Text(
                      '音量+ 上一页 / 音量- 下一页',
                      style:
                          TextStyle(fontSize: 12, color: theme.secondaryText),
                    ),
                    value: _volumePageTurn,
                    activeTrackColor: AppColors.accent,
                    onChanged: (v) {
                      setState(() => _volumePageTurn = v);
                      _notify();
                    },
                  ),
                  _sectionTitle('翻页方式', theme),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: PageTurnMode.values
                        .map((m) => _pageTurnChoice(m, theme))
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.only(top: 8, bottom: bottomInset + 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(
                  context,
                  ReaderSettings(
                    fontSize: _fontSize,
                    lineHeight: _lineHeight,
                    themeIndex: _themeIndex,
                    fontFamily: _fontFamily,
                    volumePageTurn: _volumePageTurn,
                    brightness: _brightness,
                    pageTurnMode: _pageTurnMode,
                  ),
                ),
                child: const Text('完成'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 顶部快捷操作 ----
  Widget _buildHeader(ReadingTheme theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _headerAction(
            theme,
            Icons.arrow_back_ios_new,
            '退出',
            () => Navigator.pop(context, 'exit'),
          ),
          _headerAction(theme, Icons.menu_book_outlined, '目录', () {
            Navigator.pop(context);
            widget.onOpenChapters();
          }),
          _headerAction(
            theme,
            _bookmarked ? Icons.bookmark : Icons.bookmark_border,
            _bookmarked ? '已签' : '书签',
            () {
              setState(() => _bookmarked = !_bookmarked);
              widget.onToggleBookmark();
            },
          ),
          _headerAction(
            theme,
            widget.autoScrolling
                ? Icons.pause_circle_outline
                : Icons.play_circle_outline,
            '自动',
            () {
              Navigator.pop(context);
              widget.onToggleAuto();
            },
          ),
          _headerAction(
            theme,
            Icons.record_voice_over_outlined,
            '听书',
            () {
              Navigator.pop(context);
              widget.onToggleTts();
            },
          ),
          _headerAction(
            theme,
            _themeIndex == 7
                ? Icons.wb_sunny_outlined
                : Icons.nightlight_outlined,
            _themeIndex == 7 ? '日间' : '夜间',
            () {
              final next = _themeIndex == 7 ? _lastLight : 7;
              setState(() {
                _themeIndex = next;
                if (next != 7) _lastLight = next;
              });
              _notify();
            },
          ),
        ],
      ),
    );
  }

  Widget _headerAction(
    ReadingTheme theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: theme.text),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: theme.secondaryText),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 进度 ----
  Widget _buildProgressSection(ReadingTheme theme) {
    final n = widget.totalChapters;
    if (n <= 0) return const SizedBox.shrink();
    final shown = _seeking ? _seekChapter : widget.currentChapter;
    final title = widget.chapterTitles[shown.clamp(0, n - 1)];
    final percent = _seeking
        ? ((shown / (n - 1).clamp(1, n - 1)) * 100).round()
        : (widget.progressRatio * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('进度', theme),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Text(
            '$percent% · 第 ${shown + 1}/$n 章 · $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: theme.secondaryText),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: AppColors.accent,
            inactiveTrackColor: theme.secondaryText.withValues(alpha: 0.25),
            thumbColor: AppColors.accent,
            overlayColor: AppColors.accent.withValues(alpha: 0.12),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: n <= 1 ? 0 : shown / (n - 1),
            onChanged: (v) {
              setState(() {
                _seeking = true;
                _seekChapter = (v * (n - 1)).round().clamp(0, n - 1);
              });
            },
            onChangeEnd: (v) {
              final target = (v * (n - 1)).round().clamp(0, n - 1);
              widget.onSeekChapter(target);
              // 保持 _seeking=true：面板打开期间显示停在拖到的章，
              // 真实进度（按块）等下次打开面板时重新初始化。
              setState(() => _seekChapter = target);
            },
          ),
        ),
      ],
    );
  }

  // ---- 通用小部件 ----
  Widget _sectionTitle(String t, ReadingTheme theme) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              t,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.text,
              ),
            ),
          ],
        ),
      );

  Widget _sliderRow({
    required ReadingTheme theme,
    required double min,
    required double max,
    required double value,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: theme.secondaryText.withValues(alpha: 0.25),
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child:
                Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: theme.secondaryText),
        ),
      ],
    );
  }

  void _setFont(double v) {
    setState(() => _fontSize = v.clamp(12, 32).toDouble());
    _notify();
  }

  Widget _pageTurnChoice(PageTurnMode mode, ReadingTheme theme) {
    final selected = _pageTurnMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _pageTurnMode = mode);
        _notify();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : theme.secondaryText.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? AppColors.accent
                : theme.secondaryText.withValues(alpha: 0.35),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          pageTurnLabel(mode),
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accentLight : theme.text,
          ),
        ),
      ),
    );
  }

  Widget _fontChoice(String label, String value, ReadingTheme theme) {
    final selected = _fontFamily == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _fontFamily = value);
          _notify();
        },
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : theme.secondaryText.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppColors.accent
                  : theme.secondaryText.withValues(alpha: 0.35),
              width: selected ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: value == 'default' ? null : value,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppColors.accentLight : theme.text,
            ),
          ),
        ),
      ),
    );
  }
}
