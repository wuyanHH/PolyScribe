import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/constants/app_constants.dart';
import '../services/server/http_server.dart';
import 'batch/batch_import_screen.dart';
import 'home/home_screen.dart';
import 'meeting/live_meeting_screen.dart';
import 'settings/settings_screen.dart';
import 'voiceprint/voiceprint_vault_screen.dart';

/// 全局响应式五联主导航框架 (现代深空质感 / 高刷新率优化)
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  LocalHttpServer? _localHttpServer;
  late final List<Widget> _cachedPages;

  @override
  void initState() {
    super.initState();
    _initPages();
  }

  void _initPages() {
    _cachedPages = [
      HomeScreen(
        onNavigateToMeeting: () => setState(() => _currentIndex = 1),
        onNavigateToBatch: () => setState(() => _currentIndex = 2),
      ),
      const LiveMeetingScreen(),
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
    _localHttpServer?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (isDesktop) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Row(
          children: [
            NavigationRail(
              backgroundColor: AppColors.surface,
              selectedIndex: _currentIndex,
              onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
              labelType: NavigationRailLabelType.all,
              selectedIconTheme: const IconThemeData(color: AppColors.primary, size: 22),
              unselectedIconTheme: const IconThemeData(color: AppColors.textMuted, size: 22),
              selectedLabelTextStyle: const TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
              unselectedLabelTextStyle: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
              indicatorColor: AppColors.primaryGlow,
              minWidth: 76,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Container(
                  width: 44,
                  height: 44,
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
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 24),
                  ),
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.notes_rounded),
                  selectedIcon: Icon(Icons.notes_rounded),
                  label: Text('纪要记录'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.mic_rounded),
                  selectedIcon: Icon(Icons.mic_rounded),
                  label: Text('实时会议'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.queue_music_rounded),
                  selectedIcon: Icon(Icons.queue_music_rounded),
                  label: Text('转写中心'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.fingerprint_rounded),
                  selectedIcon: Icon(Icons.fingerprint_rounded),
                  label: Text('声纹特征'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_rounded),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: Text('系统设置'),
                ),
              ],
            ),
            const VerticalDivider(width: 1, thickness: 1, color: AppColors.cardBorder),
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
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.primaryGlow,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: AppColors.primary);
            }
            return const IconThemeData(color: AppColors.textMuted);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold);
            }
            return const TextStyle(color: AppColors.textSecondary, fontSize: 11);
          }),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.notes_rounded),
              label: '记录',
            ),
            NavigationDestination(
              icon: Icon(Icons.mic_rounded),
              label: '会议',
            ),
            NavigationDestination(
              icon: Icon(Icons.queue_music_rounded),
              label: '转写',
            ),
            NavigationDestination(
              icon: Icon(Icons.fingerprint_rounded),
              label: '声纹',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_rounded),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
