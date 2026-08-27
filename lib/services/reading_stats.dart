import 'package:shared_preferences/shared_preferences.dart';

/// 全局阅读统计：累计阅读时长（只增不减）+ 格式化 helper。
class ReadingStats {
  ReadingStats._();

  static const _totalKey = 'total_read_seconds';

  static Future<int> getTotalSeconds() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_totalKey) ?? 0;
  }

  static Future<void> addTotalSeconds(int delta) async {
    if (delta <= 0) return;
    final sp = await SharedPreferences.getInstance();
    final cur = sp.getInt(_totalKey) ?? 0;
    await sp.setInt(_totalKey, cur + delta);
  }

  /// 秒 → "XhYm" / "Xm" / "0m"。
  static String formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    if (minutes < 1) return '0m';
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return rem == 0 ? '${hours}h' : '${hours}h${rem}m';
  }

  /// 字数 → "12.3万字" / "8500字"。
  static String formatWordCount(int words) {
    if (words <= 0) return '0字';
    if (words < 10000) return '$words字';
    final wan = words / 10000;
    final text = wan >= 100
        ? wan.round().toString()
        : wan.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '$text万字';
  }
}
