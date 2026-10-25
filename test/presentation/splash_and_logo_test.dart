import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/presentation/splash/splash_screen.dart';
import 'package:polyscribe/presentation/widgets/polyscribe_logo.dart';

void main() {
  group('PolyScribe 品牌徽标与动态启动页测试', () {
    testWidgets('PolyScribeLogo 静态与动态声波模式渲染正常', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PolyScribeLogo(size: 42, animate: false),
                  PolyScribeLogo(size: 96, animate: true),
                  PolyScribeLogo(size: 64, showBackground: false),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byType(PolyScribeLogo), findsNWidgets(3));
    });

    testWidgets('SplashScreen 展示品牌元素并在定时结束后平滑过渡到主界面', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SplashScreen(
            enabled: true,
            duration: Duration(milliseconds: 800),
            child: Scaffold(
              body: Center(child: Text('主工作台内容已就绪')),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('声织纪要'), findsOneWidget);
      expect(find.text('PRO'), findsOneWidget);
      expect(find.text('进入工作台'), findsOneWidget);
      expect(find.text('主工作台内容已就绪'), findsOneWidget);

      // 推进时间超过启动页设定时长 800ms + 淡出动画 420ms
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.text('主工作台内容已就绪'), findsOneWidget);
    });

    testWidgets('SplashScreen 支持点击「进入工作台」按钮立即跳过且窄屏无溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: SplashScreen(
            enabled: true,
            duration: Duration(seconds: 5),
            child: Scaffold(
              body: Center(child: Text('主界面')),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);

      // 点击右上角跳过按钮
      await tester.tap(find.text('进入工作台'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.text('主界面'), findsOneWidget);
    });
  });
}
