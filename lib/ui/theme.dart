import 'package:flutter/material.dart';

/// NetEase-Cloud-Music-inspired palette，浅色/深色共用同一套语义名。
///
/// 颜色放在静态可变字段上（而不是 `Theme.of(context)`），因为全应用的文字都写着
/// `AppTheme.textPrimary`；取色点集中在这一个文件里，换深浅色只需换这一套值。
/// 切换主题时 `LyricApp` 会带着新 key 重建整棵 home，所以不会留下旧色。
class AppTheme {
  AppTheme._();

  static const Color primary = Color(0xFFC20C0C);
  static const Color primaryLight = Color(0xFFFF4D4D);

  /// 当前是否深色。由 `LyricApp` 在每次 build 之前按设置写入。
  static bool dark = false;

  static Color get pageBg => dark ? const Color(0xFF121212) : Colors.white;
  static Color get cardBg => dark ? const Color(0xFF1D1D1D) : Colors.white;
  static Color get sheetBg => dark ? const Color(0xFF242424) : const Color(0xFFF7F7F7);
  static Color get divider => dark ? const Color(0xFF2B2B2B) : const Color(0xFFEEEEEE);
  static Color get textPrimary => dark ? const Color(0xFFE6E6E6) : const Color(0xFF333333);
  static Color get textSecondary => dark ? const Color(0xFF8C8C8C) : const Color(0xFF999999);

  /// 搜索框那种浅底药丸。
  static Color get pillBg => dark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F3F3);

  /// 图标下面的淡色圆底（收藏、下载那一类）。
  static Color get iconTint => dark ? const Color(0xFF3A2626) : const Color(0xFFFFEAEA);

  /// 「会员专享」小标签。深色下要提亮，否则金字压在黑底上根本看不清。
  static Color get vipGold => dark ? const Color(0xFFE3B873) : const Color(0xFFB07C24);

  /// 首页宫格、状态条那种淡彩底。深色下只留一点色相，整块 pastel 会刺眼。
  static Color tile(Color pastel) => dark ? pastel.withValues(alpha: .18) : pastel;

  static const cardRadius = 12.0;
  static const cardBorder = BorderRadius.all(Radius.circular(cardRadius));

  /// Material 自己的弹层（对话框、下拉菜单、输入框）也跟着走，
  /// 免得页面是黑的、弹窗还是白的。
  static ThemeData palette() {
    final base = dark ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: primary, secondary: primary, surface: pageBg),
      scaffoldBackgroundColor: pageBg,
      cardColor: cardBg,
      appBarTheme: AppBarTheme(
        backgroundColor: pageBg,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600).copyWith(color: textPrimary),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF181818) : Colors.white,
        selectedItemColor: primary,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      textTheme: base.textTheme.apply(bodyColor: textPrimary, displayColor: textPrimary),
    );
  }
}

String formatPlayTime(int? sec) {
  if (sec == null) return '--:--';
  final m = sec ~/ 60, s = sec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
