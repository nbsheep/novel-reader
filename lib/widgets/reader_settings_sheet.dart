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

/// 阅读设置（由底部弹窗返回给阅读页）。
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

class ReaderSettingsSheet extends StatefulWidget {
  final double fontSize;
  final double lineHeight;
  final int themeIndex;
  final String fontFamily;
  final bool volumePageTurn;
  final double brightness;
  final PageTurnMode pageTurnMode;
  final ValueChanged<ReaderSettings>? onChanged;

  const ReaderSettingsSheet({
    super.key,
    required this.fontSize,
    required this.lineHeight,
    required this.themeIndex,
    required this.fontFamily,
    this.volumePageTurn = false,
    this.brightness = 1.0,
    this.pageTurnMode = PageTurnMode.scroll,
    this.onChanged,
  });

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late double _fontSize;
  late double _lineHeight;
  late int _themeIndex;
  late String _fontFamily;
  late bool _volumePageTurn;
  late double _brightness;
  late PageTurnMode _pageTurnMode;

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
  }

  void _notify() {
    widget.onChanged?.call(ReaderSettings(
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
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('背景颜色'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: List.generate(readingThemes.length, (i) {
              final t = readingThemes[i];
              final selected = i == _themeIndex;
              return GestureDetector(
                onTap: () {
                  setState(() => _themeIndex = i);
                  _notify();
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: t.background,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? AppColors.accent : Colors.white24,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: selected
                      ? Icon(Icons.check, size: 20, color: t.text)
                      : null,
                ),
              );
            }),
          ),
          const SizedBox(height: 20),
          _sectionTitle('亮度'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _brightness,
                  min: 0.3,
                  max: 1.0,
                  onChanged: (v) {
                    setState(() => _brightness = v);
                    _notify();
                  },
                ),
              ),
              Text(
                '${(_brightness * 100).round()}%',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionTitle('字号'),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => _setFont(_fontSize - 1),
              ),
              Expanded(
                child: Slider(
                  value: _fontSize,
                  min: 12,
                  max: 32,
                  onChanged: (v) {
                    setState(() => _fontSize = v);
                    _notify();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _setFont(_fontSize + 1),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _sectionTitle('行距'),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _lineHeight,
                  min: 1.2,
                  max: 2.6,
                  onChanged: (v) {
                    setState(() => _lineHeight = v);
                    _notify();
                  },
                ),
              ),
              Text(
                _lineHeight.toStringAsFixed(1),
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionTitle('字体'),
          Row(
            children: [
              _fontChoice('默认', 'default'),
              _fontChoice('衬线', 'serif'),
              _fontChoice('等宽', 'monospace'),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              '音量键翻页',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: const Text(
              '音量+ 上一页 / 音量- 下一页',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            value: _volumePageTurn,
            activeTrackColor: AppColors.accent,
            onChanged: (v) {
              setState(() => _volumePageTurn = v);
              _notify();
            },
          ),
          const SizedBox(height: 16),
          _sectionTitle('翻页方式'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: PageTurnMode.values
                .map((m) => _pageTurnChoice(m))
                .toList(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
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
              child: const Text('确定'),
            ),
          ),
        ],
      ),
    );
  }

  void _setFont(double v) {
    setState(() => _fontSize = v.clamp(12, 32).toDouble());
    _notify();
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      );

  Widget _pageTurnChoice(PageTurnMode mode) {
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
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          pageTurnLabel(mode),
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accentLight : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _fontChoice(String label, String value) {
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
                : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: value == 'default' ? null : value,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppColors.accentLight : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
