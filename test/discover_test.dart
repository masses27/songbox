import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/ui/pages/discover_page.dart';

/// 发现页的布局冒烟测。
///
/// 这一页的接口在测试里是打不通的（flutter_test 把 HttpClient 换成了回 400 的假货），
/// 所以歌单和榜单两块都会落到报错那一格——这里要看的本来也不是数据，是那两块新的控件
/// 在 360 宽的屏上摆得下摆不下：分类面板展开、收起对不对，有没有溢出报错。
void main() {
  Future<void> openPanel(WidgetTester tester) async {
    await tester.dragUntilVisible(find.text('全部分类'), find.byType(ListView).first, const Offset(-120, 0));
    await tester.pump();
    await tester.tap(find.text('全部分类'));
    await tester.pump();
  }

  /// 在飞的请求把超时定时器留在 fake clock 上，不收尾的话测试结束就报「还有 Timer」。
  Future<void> drain(WidgetTester tester) => tester.pump(const Duration(seconds: 30));

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DiscoverPage())));
    await tester.pump();
  }

  testWidgets('横向那一排末尾有「全部分类」，摊开能看到收起来的词', (tester) async {
    await pumpPage(tester);
    expect(find.text('歌单分类'), findsOneWidget);
    // 那颗排在分类行末尾，得先把那一行划到头。
    await openPanel(tester);
    expect(find.text('语种'), findsOneWidget);
    expect(find.text('意大利语'), findsOneWidget, reason: '横向那一排没有的词就该在面板里');
    expect(find.text('收起分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('在面板里挑一个分类，面板自己收起', (tester) async {
    await pumpPage(tester);
    await openPanel(tester);
    await tester.tap(find.text('意大利语'));
    await tester.pump();
    expect(find.text('语种'), findsNothing, reason: '挑完还摊着的话，歌单永远被压在面板下面');
    expect(find.text('全部分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('接口回不来时这一页不炸，也不铺分组标题', (tester) async {
    await pumpPage(tester);
    expect(find.text('榜单'), findsOneWidget);
    // 原来 60 多个榜全铺的时候，光分组标题就有四行，这一页要滚三屏才到得了榜单。
    expect(find.text('风格榜'), findsNothing);
    expect(find.text('海外榜'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });
}
