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

/// PolyScribe 语义化设计调色板扩展 (遵循 Flutter 官方标准 ThemeExtension 规范)
@immutable
class PolyScribePalette extends ThemeExtension<PolyScribePalette> {
  final Color bg;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color textMain;
  final Color textSub;
  final Color textMuted;
  final Color primary;
  final Color emerald;
  final Color amber;
  final Color rose;
  final Color cyan;

  const PolyScribePalette({
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.textMain,
    required this.textSub,
    required this.textMuted,
    required this.primary,
    required this.emerald,
    required this.amber,
    required this.rose,
    required this.cyan,
  });

  static const PolyScribePalette dark = PolyScribePalette(
    bg: AppColors.background,
    surface: AppColors.surface,
    surfaceElevated: AppColors.surfaceElevated,
    border: AppColors.cardBorder,
    textMain: AppColors.textPrimary,
    textSub: AppColors.textSecondary,
    textMuted: AppColors.textMuted,
    primary: AppColors.primary,
    emerald: AppColors.emerald,
    amber: AppColors.amber,
    rose: AppColors.rose,
    cyan: AppColors.cyan,
  );

  static const PolyScribePalette light = PolyScribePalette(
    bg: AppColors.lightBackground,
    surface: AppColors.lightSurface,
    surfaceElevated: AppColors.lightSurfaceElevated,
    border: AppColors.lightCardBorder,
    textMain: AppColors.lightTextPrimary,
    textSub: AppColors.lightTextSecondary,
    textMuted: AppColors.lightTextMuted,
    primary: AppColors.primary,
    emerald: AppColors.emerald,
    amber: AppColors.amber,
    rose: AppColors.rose,
    cyan: AppColors.cyan,
  );

  @override
  PolyScribePalette copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceElevated,
    Color? border,
    Color? textMain,
    Color? textSub,
    Color? textMuted,
    Color? primary,
    Color? emerald,
    Color? amber,
    Color? rose,
    Color? cyan,
  }) {
    return PolyScribePalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      border: border ?? this.border,
      textMain: textMain ?? this.textMain,
      textSub: textSub ?? this.textSub,
      textMuted: textMuted ?? this.textMuted,
      primary: primary ?? this.primary,
      emerald: emerald ?? this.emerald,
      amber: amber ?? this.amber,
      rose: rose ?? this.rose,
      cyan: cyan ?? this.cyan,
    );
  }

  @override
  PolyScribePalette lerp(ThemeExtension<PolyScribePalette>? other, double t) {
    if (other is! PolyScribePalette) return this;
    return PolyScribePalette(
      bg: Color.lerp(bg, other.bg, t) ?? bg,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t) ?? surfaceElevated,
      border: Color.lerp(border, other.border, t) ?? border,
      textMain: Color.lerp(textMain, other.textMain, t) ?? textMain,
      textSub: Color.lerp(textSub, other.textSub, t) ?? textSub,
      textMuted: Color.lerp(textMuted, other.textMuted, t) ?? textMuted,
      primary: Color.lerp(primary, other.primary, t) ?? primary,
      emerald: Color.lerp(emerald, other.emerald, t) ?? emerald,
      amber: Color.lerp(amber, other.amber, t) ?? amber,
      rose: Color.lerp(rose, other.rose, t) ?? rose,
      cyan: Color.lerp(cyan, other.cyan, t) ?? cyan,
    );
  }
}

/// 应用主题样式工厂 (沉浸暗黑与清新明亮)
class AppTheme {
  AppTheme._();

  /// 浅色清新主题 (极简白/亮灰蓝)
  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: AppColors.lightBackground,
      canvasColor: AppColors.lightSurface,
      extensions: const [PolyScribePalette.light],
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        secondary: AppColors.emerald,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightTextPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightSurface,
        foregroundColor: AppColors.lightTextPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        iconTheme: IconThemeData(color: AppColors.lightTextPrimary),
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.lightCardBorder),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.lightCardBorder,
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
      extensions: const [PolyScribePalette.dark],
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
        iconTheme: IconThemeData(color: Colors.white),
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
