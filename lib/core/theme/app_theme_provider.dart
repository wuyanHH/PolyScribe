import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants/app_colors.dart';
import '../../data/database/app_database.dart';

/// 全局主题模式控制器 (遵循 Riverpod 3.x 标准 Notifier)
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _settingKey = 'app_theme_mode';

  @override
  ThemeMode build() {
    _loadPersistedTheme();
    return ThemeMode.dark;
  }

  Future<void> _loadPersistedTheme() async {
    try {
      final saved = await AppDatabase.instance.getSetting(_settingKey);
      if (saved == 'light') {
        state = ThemeMode.light;
      } else if (saved == 'system') {
        state = ThemeMode.system;
      } else {
        state = ThemeMode.dark;
      }
    } catch (_) {
      state = ThemeMode.dark;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    String val = 'dark';
    if (mode == ThemeMode.light) {
      val = 'light';
    } else if (mode == ThemeMode.system) {
      val = 'system';
    }
    try {
      await AppDatabase.instance.saveSetting(_settingKey, val);
    } catch (_) {}
  }
}

/// 全局主题 Provider (Riverpod 3.x NotifierProvider)
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(() {
  return ThemeModeNotifier();
});

/// 应用主题样式工厂 (沉浸暗黑与清新明亮)
class AppTheme {
  AppTheme._();

  /// 浅色清新主题 (极简白/亮灰蓝)
  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      canvasColor: const Color(0xFFFFFFFF),
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        secondary: AppColors.emerald,
        surface: Color(0xFFFFFFFF),
        onSurface: Color(0xFF0F172A),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFFFF),
        foregroundColor: Color(0xFF0F172A),
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFFFFFFF),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE2E8F0),
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1E293B),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF334155)),
        ),
        elevation: 6,
      ),
      useMaterial3: true,
    );
  }

  /// 深色沉浸主题 (极客 Slate 950 / 深蓝灰)
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.surface,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.emerald,
        surface: AppColors.surface,
        onSurface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.cardBorder,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceElevated,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppColors.cardBorder),
        ),
        elevation: 6,
      ),
      useMaterial3: true,
    );
  }
}
