import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/app.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('PolyScribeApp 启动并渲染主界面测试', (WidgetTester tester) async {
    await tester.pumpWidget(const PolyScribeApp());
    // 渲染第一帧
    await tester.pump();
    // 推进异步初始化与数据加载
    await tester.pump(const Duration(milliseconds: 300));

    // 验证品牌标识与主页标题
    expect(find.text('声织'), findsAtLeastNWidgets(1));
    expect(find.text('纪要与转写历史'), findsOneWidget);
  });
}
