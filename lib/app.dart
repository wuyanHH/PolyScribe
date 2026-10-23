import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme_provider.dart';
import 'presentation/main_navigation_screen.dart';

/// PolyScribe 根应用组件 (内置 ProviderScope 并在 Consumer 中响应全局主题)
class PolyScribeApp extends StatelessWidget {
  const PolyScribeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: Consumer(
        builder: (context, ref, child) {
          final themeMode = ref.watch(themeModeProvider);

          return MaterialApp(
            title: AppConstants.appFullName,
            debugShowCheckedModeBanner: false,
            themeMode: themeMode,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            home: const MainNavigationScreen(),
          );
        },
      ),
    );
  }
}
