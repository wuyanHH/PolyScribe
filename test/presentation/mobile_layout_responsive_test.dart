import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/data/models/meeting_task.dart';
import 'package:polyscribe/presentation/models/model_manager_screen.dart';
import 'package:polyscribe/presentation/player/sync_player_screen.dart';
import 'package:polyscribe/presentation/settings/subpages/storage_settings_screen.dart';
import 'package:polyscribe/presentation/voiceprint/voiceprint_vault_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('手机窄屏 (360px & 320px) 响应式布局防溢出测试', () {
    testWidgets('StorageSettingsScreen 在 360px 窄屏下无任何 RenderFlex 溢出', (tester) async {
      // 模拟标准 360px 宽度手机屏幕
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: StorageSettingsScreen(),
          ),
        ),
      );
      // 推进多帧直至异步数据加载完毕
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 验证无任何布局溢出异常
      expect(tester.takeException(), isNull);
      expect(find.text('数据存储与空间维护'), findsOneWidget);
    });

    testWidgets('VoiceprintVaultScreen 在 360px 窄屏下滑动条刻度无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: VoiceprintVaultScreen(),
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(tester.takeException(), isNull);
      expect(find.text('实名声纹特征库'), findsOneWidget);
    });

    testWidgets('ModelManagerScreen 在 360px 窄屏下标题与卡片无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: ModelManagerScreen(),
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(tester.takeException(), isNull);
      expect(find.text('AI 端侧模型管理'), findsOneWidget);
    });

    testWidgets('SyncPlayerScreen 在 360px 窄屏下 AppBar actions 与底栏自适应无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mockTask = MeetingTask(
        id: 'test_task_mobile',
        title: '移动端超长标题自适应会议纪要测试文本',
        audioPath: '',
        durationMs: 120000,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        sourceType: TaskSourceType.importedAudio,
        status: TaskStatus.completed,
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: SyncPlayerScreen(task: mockTask),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      // 验证 AppBar 中的纪要标题成功渲染且没有被溢出挤压崩溃
      expect(find.text('移动端超长标题自适应会议纪要测试文本'), findsOneWidget);
    });
  });
}
