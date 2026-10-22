import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/constants/app_constants.dart';
import '../services/server/http_server.dart';
import 'batch/batch_import_screen.dart';
import 'home/home_screen.dart';
import 'meeting/live_meeting_screen.dart';
import 'settings/settings_screen.dart';
import 'voiceprint/voiceprint_vault_screen.dart';

/// 全局响应式五联主导航框架
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  LocalHttpServer? _localHttpServer;

  @override
  void initState() {
    super.initState();
  }

  void _toggleServer() async {
    if (_localHttpServer != null && _localHttpServer!.isRunning) {
      await _localHttpServer!.stop();
      setState(() {});
    } else {
      _localHttpServer = LocalHttpServer(port: AppConstants.defaultServerPort);
      await _localHttpServer!.start();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _localHttpServer?.stop();
    super.dispose();
  }

  List<Widget> _buildPages() {
    return [
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

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final pages = _buildPages();

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
              selectedIconTheme: const IconThemeData(color: AppColors.primary),
              unselectedIconTheme: const IconThemeData(color: Colors.grey),
              selectedLabelTextStyle: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.bold),
              unselectedLabelTextStyle: const TextStyle(color: Colors.grey, fontSize: 11),
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    AppConstants.appShortName,
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.notes_rounded),
                  selectedIcon: Icon(Icons.notes_rounded, color: AppColors.primary),
                  label: Text('纪要记录'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.mic_rounded),
                  selectedIcon: Icon(Icons.mic_rounded, color: AppColors.primary),
                  label: Text('实时会议'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.queue_music_rounded),
                  selectedIcon: Icon(Icons.queue_music_rounded, color: AppColors.primary),
                  label: Text('转写中心'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.fingerprint_rounded),
                  selectedIcon: Icon(Icons.fingerprint_rounded, color: AppColors.primary),
                  label: Text('声纹特征'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_rounded),
                  selectedIcon: Icon(Icons.settings_rounded, color: AppColors.primary),
                  label: Text('系统设置'),
                ),
              ],
            ),
            const VerticalDivider(width: 1, color: AppColors.surfaceLight),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: pages,
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
        children: pages,
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.primary.withValues(alpha: 0.2),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: AppColors.primary);
            }
            return const IconThemeData(color: Colors.grey);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold);
            }
            return const TextStyle(color: Colors.grey, fontSize: 11);
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
