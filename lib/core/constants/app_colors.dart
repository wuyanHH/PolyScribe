import 'package:flutter/material.dart';

/// PolyScribe (声织纪要) 多角色专用视觉规范与调色板
class AppColors {
  AppColors._();

  /// 当前全局是否为暗色模式（由根组件 MaterialApp / themeMode 同步状态）
  static bool isDark = true;

  // 品牌核心主色
  static const Color primary = Color(0xFFF97316); // 活力珊瑚橙
  static const Color primaryDark = Color(0xFFEA580C);
  static const Color primaryGlow = Color(0x40F97316);
  static const Color background = Color(0xFF0B0F19); // 更深邃沉浸的深黑背景 (Slate 950)
  static const Color surface = Color(0xFF131B2E); // 科技深蓝灰卡片表面
  static const Color surfaceLight = Color(0xFF1E293B);
  static const Color surfaceElevated = Color(0xFF1F293D);
  static const Color cardBorder = Color(0xFF26334D);
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);
  static const Color emerald = Color(0xFF10B981);
  static const Color amber = Color(0xFFF59E0B);
  static const Color rose = Color(0xFFF43F5E);
  static const Color cyan = Color(0xFF06B6D4);

  // 浅色主题对应规范色彩
  static const Color lightBackground = Color(0xFFF8FAFC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceElevated = Color(0xFFF1F5F9);
  static const Color lightCardBorder = Color(0xFFE2E8F0);
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

  /// 六大预设角色专属高对比度色彩池
  static const List<SpeakerColor> speakerPalette = [
    SpeakerColor(
      id: 'SPK_01',
      defaultRoleName: '主讲人 / 我方发言',
      colorName: '活力珊瑚橙',
      color: Color(0xFFF97316),
      surfaceColor: Color(0x26F97316),
    ),
    SpeakerColor(
      id: 'SPK_02',
      defaultRoleName: '主要嘉宾 A',
      colorName: '翡翠薄荷绿',
      color: Color(0xFF10B981),
      surfaceColor: Color(0x2610B981),
    ),
    SpeakerColor(
      id: 'SPK_03',
      defaultRoleName: '参会嘉宾 B',
      colorName: '星云电光蓝',
      color: Color(0xFF38BDF8),
      surfaceColor: Color(0x2638BDF8),
    ),
    SpeakerColor(
      id: 'SPK_04',
      defaultRoleName: '参会嘉宾 C',
      colorName: '紫罗兰',
      color: Color(0xFFA855F7),
      surfaceColor: Color(0x26A855F7),
    ),
    SpeakerColor(
      id: 'SPK_05',
      defaultRoleName: '参会嘉宾 D',
      colorName: '琥珀金',
      color: Color(0xFFEAB308),
      surfaceColor: Color(0x26EAB308),
    ),
    SpeakerColor(
      id: 'SPK_06',
      defaultRoleName: '参会嘉宾 E 及其他',
      colorName: '玫瑰粉',
      color: Color(0xFFEC4899),
      surfaceColor: Color(0x26EC4899),
    ),
  ];

  /// 根据角色 ID (如 SPK_01 或索引) 轮询获取专属色彩配置
  static SpeakerColor getSpeakerColor(String? speakerId, {int index = 0}) {
    if (speakerId != null) {
      final found = speakerPalette.where((c) => c.id == speakerId);
      if (found.isNotEmpty) return found.first;
      // 尝试匹配数字尾缀
      final match = RegExp(r'(\d+)').firstMatch(speakerId);
      if (match != null) {
        final num = int.tryParse(match.group(1)!) ?? 1;
        return speakerPalette[(num - 1) % speakerPalette.length];
      }
    }
    return speakerPalette[index % speakerPalette.length];
  }
}

/// 角色色彩封装结构
class SpeakerColor {
  final String id;
  final String defaultRoleName;
  final String colorName;
  final Color color;
  final Color surfaceColor;

  const SpeakerColor({
    required this.id,
    required this.defaultRoleName,
    required this.colorName,
    required this.color,
    required this.surfaceColor,
  });
}

/// 全局动态色彩上下文感知扩展 (实时响应深浅色主题模式切换)
extension AppThemeColors on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get bg => isDark ? AppColors.background : AppColors.lightBackground;
  Color get surfaceColor => isDark ? AppColors.surface : AppColors.lightSurface;
  Color get surfaceElevatedColor => isDark ? AppColors.surfaceElevated : AppColors.lightSurfaceElevated;
  Color get borderColor => isDark ? AppColors.cardBorder : AppColors.lightCardBorder;
  Color get textMain => isDark ? AppColors.textPrimary : AppColors.lightTextPrimary;
  Color get textSub => isDark ? AppColors.textSecondary : AppColors.lightTextSecondary;
  Color get textGrey => isDark ? AppColors.textMuted : AppColors.lightTextMuted;
}
