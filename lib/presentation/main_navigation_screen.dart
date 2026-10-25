import 'dart:async';
import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/constants/app_constants.dart';
import '../data/models/meeting_task.dart';
import '../services/server/http_server.dart';
import '../services/task_queue_service.dart';
import 'batch/batch_import_screen.dart';
import 'home/home_screen.dart';
import 'meeting/live_meeting_screen.dart';
import 'models/model_manager_screen.dart';
import 'settings/settings_screen.dart';
import 'voiceprint/voiceprint_vault_screen.dart';

/// 全局响应式五联主导航框架 (现代深空质感 / 桌面端侧边工作台 + 移动端底部导航)
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  LocalHttpServer? _localHttpServer;
  late List<Widget> _cachedPages;
  StreamSubscription<TaskProgressEvent>? _queueSub;
  bool _isQueueBusy = false;

  @override
  void initState() {
    super.initState();
    _initPages();
    _queueSub = TaskQueueService.instance.onProgress.listen((event) {
      final busy = event.status == TaskStatus.processing || event.status == TaskStatus.queued;
      if (mounted && _isQueueBusy != busy) {
        setState(() {
          _isQueueBusy = busy;
        });
      }
    });
  }

  void _initPages() {
    _cachedPages = [
      HomeScreen(
        onNavigateToMeeting: () => setState(() => _currentIndex = 1),
        onNavigateToBatch: () => setState(() => _currentIndex = 2),
      ),
      LiveMeetingScreen(
        onBackToHome: () => setState(() => _currentIndex = 0),
      ),
      const BatchImportScreen(),
      const VoiceprintVaultScreen(),
      SettingsScreen(
        localHttpServer: _localHttpServer,
        onToggleServer: _toggleServer,
      ),
    ];
  }

  void _toggleServer() async {
    if (_localHttpServer != null && _localHttpServer!.isRunning) {
      await _localHttpServer!.stop();
    } else {
      _localHttpServer = LocalHttpServer(port: AppConstants.defaultServerPort);
      await _localHttpServer!.start();
    }
    if (mounted) {
      setState(() {
        _initPages();
      });
    }
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    _localHttpServer?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width >= 768;
    final isWideDesktop = width >= 1180;
    final isServerRunning = _localHttpServer?.isRunning ?? false;

    if (isDesktop) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Row(
          children: [
            _buildDesktopSidebar(isWideDesktop, isServerRunning),
            VerticalDivider(width: 1, thickness: 1, color: AppColors.cardBorder),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _cachedPages,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _currentIndex,
        children: _cachedPages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1)),
        ),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: AppColors.surface,
            indicatorColor: AppColors.primaryGlow,
            height: 66,
            iconTheme: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return const IconThemeData(color: AppColors.primary, size: 22);
              }
              return IconThemeData(color: AppColors.textMuted, size: 21);
            }),
            labelTextStyle: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold);
              }
              return TextStyle(color: AppColors.textSecondary, fontSize: 11);
            }),
          ),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.notes_rounded),
                label: '纪要库',
              ),
              const NavigationDestination(
                icon: Icon(Icons.mic_rounded),
                label: '实时会议',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: _isQueueBusy,
                  backgroundColor: AppColors.primary,
                  child: const Icon(Icons.queue_music_rounded),
                ),
                label: '转写队列',
              ),
              const NavigationDestination(
                icon: Icon(Icons.fingerprint_rounded),
                label: '声纹库',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_rounded),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 桌面端专业工作台侧边导航栏 (支持宽屏展开与窄屏紧凑自适应)
  Widget _buildDesktopSidebar(bool isExtended, bool isServerRunning) {
    final navItems = [
      _NavItemData(
        icon: Icons.dashboard_customize_rounded,
        label: '纪要库',
        subtitle: '历史与全文检索',
      ),
      _NavItemData(
        icon: Icons.mic_rounded,
        label: '实时会议',
        subtitle: '多音源在线聚类',
      ),
      _NavItemData(
        icon: Icons.queue_music_rounded,
        label: '转写中心',
        subtitle: '外部音频批处理',
        showBadge: _isQueueBusy,
      ),
      _NavItemData(
        icon: Icons.fingerprint_rounded,
        label: '声纹特征',
        subtitle: '192维实名档案',
      ),
      _NavItemData(
        icon: Icons.settings_suggest_rounded,
        label: '系统设置',
        subtitle: '引擎与服务配置',
      ),
    ];

    return Container(
      width: isExtended ? 228 : 84,
      color: AppColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            // 顶部品牌标识区
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isExtended ? 18 : 12,
                vertical: 20,
              ),
              child: Row(
                mainAxisAlignment: isExtended ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, AppColors.primaryDark],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 24),
                    ),
                  ),
                  if (isExtended) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                AppConstants.appFullName,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const _ProBadge(),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            AppConstants.appEnglishName,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.cardBorder),
            const SizedBox(height: 12),

            // 导航菜单列表
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.symmetric(horizontal: isExtended ? 12 : 10),
                itemCount: navItems.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, idx) {
                  final item = navItems[idx];
                  final isSelected = _currentIndex == idx;

                  return Tooltip(
                    message: isExtended ? '' : '${item.label} (${item.subtitle})',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setState(() => _currentIndex = idx),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: EdgeInsets.symmetric(
                            horizontal: isExtended ? 14 : 0,
                            vertical: isExtended ? 11 : 12,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary.withValues(alpha: 0.14)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary.withValues(alpha: 0.45)
                                  : Colors.transparent,
                            ),
                          ),
                          child: isExtended
                              ? Row(
                                  children: [
                                    Badge(
                                      isLabelVisible: item.showBadge,
                                      backgroundColor: AppColors.primary,
                                      child: Icon(
                                        item.icon,
                                        size: 21,
                                        color: isSelected ? AppColors.primary : AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.label,
                                            style: TextStyle(
                                              color: isSelected ? AppColors.primary : AppColors.textPrimary,
                                              fontSize: 13.5,
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                            ),
                                          ),
                                          Text(
                                            item.subtitle,
                                            style: TextStyle(
                                              color: isSelected
                                                  ? AppColors.primary.withValues(alpha: 0.85)
                                                  : AppColors.textMuted,
                                              fontSize: 10.5,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isSelected)
                                      Container(
                                        width: 5,
                                        height: 18,
                                        decoration: BoxDecoration(
                                          color: AppColors.primary,
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                      ),
                                  ],
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Badge(
                                      isLabelVisible: item.showBadge,
                                      backgroundColor: AppColors.primary,
                                      child: Icon(
                                        item.icon,
                                        size: 22,
                                        color: isSelected ? AppColors.primary : AppColors.textMuted,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      item.label,
                                      style: TextStyle(
                                        color: isSelected ? AppColors.primary : AppColors.textSecondary,
                                        fontSize: 11,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // 底部快捷模型中心与本地 API 状态指示卡
            Padding(
              padding: EdgeInsets.all(isExtended ? 12 : 8),
              child: Column(
                children: [
                  // 快捷打开 AI 模型中心
                  Tooltip(
                    message: 'AI 离线模型管理中心',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
                        );
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: isExtended ? 12 : 8,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: isExtended
                            ? const Row(
                                children: [
                                  Icon(Icons.memory_rounded, size: 17, color: AppColors.primary),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'AI 模型管理中心',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.open_in_new_rounded, size: 13, color: AppColors.textMuted),
                                ],
                              )
                            : const Center(
                                child: Icon(Icons.memory_rounded, size: 20, color: AppColors.primary),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // STT 转发服务状态微胶囊
                  Tooltip(
                    message: isServerRunning
                        ? '本地 STT 服务运行中 (127.0.0.1:${AppConstants.defaultServerPort})'
                        : '点击开启本地 STT 转发服务',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _toggleServer,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: isExtended ? 12 : 8,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: isServerRunning
                              ? AppColors.emerald.withValues(alpha: 0.12)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isServerRunning
                                ? AppColors.emerald.withValues(alpha: 0.4)
                                : AppColors.cardBorder,
                          ),
                        ),
                        child: isExtended
                            ? Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      isServerRunning ? 'STT API 运行中' : 'STT API 待机',
                                      style: TextStyle(
                                        color: isServerRunning ? AppColors.emerald : AppColors.textSecondary,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    ':${AppConstants.defaultServerPort}',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              )
                            : Center(
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItemData {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool showBadge;

  const _NavItemData({
    required this.icon,
    required this.label,
    required this.subtitle,
    this.showBadge = false,
  });
}

class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.5), width: 0.8),
      ),
      child: const Text(
        'PRO',
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

