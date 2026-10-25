import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/theme/app_theme_provider.dart';

/// 视觉外观与主题设置二级页面
class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeModeProvider);
    final isCompact = MediaQuery.of(context).size.width < 640;

    final tabs = [
      _ThemeTabItem(
        mode: ThemeMode.dark,
        title: '深色沉浸',
        subtitle: '科技深蓝黑 · 夜间专注舒适',
        icon: Icons.dark_mode_rounded,
        accentColor: const Color(0xFF6366F1),
        previewBg: const Color(0xFF0F172A),
        previewCardBg: const Color(0xFF1E293B),
        previewTextColor: Colors.white70,
      ),
      _ThemeTabItem(
        mode: ThemeMode.light,
        title: '明亮清新',
        subtitle: '极简素雅白 · 日间清晰护眼',
        icon: Icons.light_mode_rounded,
        accentColor: const Color(0xFFF59E0B),
        previewBg: const Color(0xFFF1F5F9),
        previewCardBg: Colors.white,
        previewTextColor: const Color(0xFF334155),
      ),
      _ThemeTabItem(
        mode: ThemeMode.system,
        title: '跟随系统',
        subtitle: '感应设备系统外观模式自动匹配',
        icon: Icons.brightness_auto_rounded,
        accentColor: AppColors.emerald,
        previewBg: const Color(0xFF1A1F2C),
        previewCardBg: const Color(0xFF283145),
        previewTextColor: Colors.white60,
      ),
    ];

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: context.textMain),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '视觉外观与主题风格',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 20, vertical: 16),
            physics: const BouncingScrollPhysics(),
            children: [
              // 选项卡分组
              Container(
                padding: EdgeInsets.all(isCompact ? 14 : 18),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择外观风格',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textMain),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'PolyScribe 适配深色微质感与浅色极简模式，可在任意时刻自由切换',
                      style: TextStyle(fontSize: 12, color: context.textGrey),
                    ),
                    const SizedBox(height: 16),
                    ...tabs.map((tab) {
                      final isSelected = currentTheme == tab.mode;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? tab.accentColor.withValues(alpha: 0.12)
                              : (context.isDark ? AppColors.background : const Color(0xFFF1F5F9)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? tab.accentColor : context.borderColor,
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            ref.read(themeModeProvider.notifier).setThemeMode(tab.mode);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: tab.accentColor.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(tab.icon, color: tab.accentColor, size: 22),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tab.title,
                                        style: TextStyle(
                                          color: isSelected ? tab.accentColor : context.textMain,
                                          fontSize: 14,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        tab.subtitle,
                                        style: TextStyle(color: context.textGrey, fontSize: 11.5),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isSelected)
                                  Icon(Icons.check_circle_rounded, color: tab.accentColor, size: 22)
                                else
                                  Icon(Icons.circle_outlined, color: context.textGrey, size: 20),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 调色板与渲染说明
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.borderColor),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '修改主题模式后将即时在主导航、实时会议、播放看板与设置页生效并自动写入本地配置。',
                        style: TextStyle(color: context.textSub, fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeTabItem {
  final ThemeMode mode;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final Color previewBg;
  final Color previewCardBg;
  final Color previewTextColor;

  const _ThemeTabItem({
    required this.mode,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.previewBg,
    required this.previewCardBg,
    required this.previewTextColor,
  });
}
