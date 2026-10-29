// 桌面版（鼠标指针）下的横向轮播手感。
//
// 她那句「windows的这个地方不能点击，不能移动，点下面的小点也不会切换」里，
// 用鼠标点卡其实是通的（真机上点过，确实进了歌单），不通的是另外三样：Flutter
// 默认不把鼠标算进 scrollable 的拖拽设备，横向排又收不到竖向滚轮，指示点更是只画
// 了个色块、压根没接命中。这里把三样都按鼠标指针钉住，另外补一条「不加
// MouseDragScroll 就拖不动」的对照，免得哪天有人把这套配置撤了却没人发现。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/models/results.dart';
import 'package:lyric_music/ui/pages/home_page.dart';
import 'package:lyric_music/ui/widgets.dart';

SheetInfo _sheet(int i) => SheetInfo('wy', 's$i', '轮播$i', null, null);

List<SheetInfo> _five() => List.generate(5, _sheet);

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

/// 第 i 张现在停在屏幕哪个横坐标上。轮播每页居中，所以「谁在中间」就是当前页。
double _centerX(WidgetTester tester, String label) =>
    tester.getCenter(find.text(label)).dx;

/// 从这张卡正中起手势：落点必须真落在卡上，否则拖的是空白处，等于没测。
Offset _onCard(WidgetTester tester, String label) => tester.getCenter(find.text(label));

/// 用指针横拖 dx。先动 40 是起势：这一段 delta 会被「判给谁」那一帧丢掉，
/// 真正拖出去的是剩下的部分，所以拖距要按剩下的这些算。
Future<void> _dragWith(WidgetTester tester, Offset from, double dx, PointerDeviceKind kind) async {
  final wake = dx.sign * 40;
  final g = await tester.startGesture(from, kind: kind);
  await g.moveBy(Offset(wake, 0));
  await tester.pump(const Duration(milliseconds: 30));
  await g.moveBy(Offset(dx - wake, 0));
  await tester.pump(const Duration(milliseconds: 30));
  await g.up();
  await tester.pumpAndSettle();
}

Future<void> _mouseDrag(WidgetTester tester, Offset from, double dx) =>
    _dragWith(tester, from, dx, PointerDeviceKind.mouse);

/// 拖过页宽大半才松手：只拖一点点，PageView 会弹回当前页，看不出拖没拖得动。
double _pageStep(WidgetTester tester) => _centerX(tester, '轮播1') - _centerX(tester, '轮播0');

void main() {
  testWidgets('鼠标点整张轮播卡仍然进歌单', (tester) async {
    SheetInfo? opened;
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (s) => opened = s, arrows: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('轮播0'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(opened?.id, 's0');
  });

  testWidgets('鼠标横拖能翻页', (tester) async {
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (_) {}, arrows: true)));
    await tester.pumpAndSettle();
    final slot = _centerX(tester, '轮播0');
    final step = _pageStep(tester);

    await _mouseDrag(tester, _onCard(tester, '轮播0'), -step * 0.7);

    expect(_centerX(tester, '轮播1'), closeTo(slot, 2));
  });

  testWidgets('点小点跳到那一张', (tester) async {
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (_) {}, arrows: true)));
    await tester.pumpAndSettle();
    final mid = _centerX(tester, '轮播0');

    await tester.tap(find.byKey(const ValueKey('banner-dot-3')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(_centerX(tester, '轮播3'), closeTo(mid, 2));
  });

  testWidgets('点当前这个小点不会把页跳走', (tester) async {
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (_) {}, arrows: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('banner-dot-3')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final mid = _centerX(tester, '轮播3');

    await tester.tap(find.byKey(const ValueKey('banner-dot-3')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(_centerX(tester, '轮播3'), closeTo(mid, 2));
  });

  testWidgets('左右箭头各翻一张，走到头那颗不接点击', (tester) async {
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (_) {}, arrows: true)));
    await tester.pumpAndSettle();
    final first = _centerX(tester, '轮播0');

    // 停在第一张时左箭头是灰的：点它不该有任何动静。
    await tester.tap(find.byKey(const ValueKey('banner-prev')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_centerX(tester, '轮播0'), closeTo(first, 2));

    await tester.tap(find.byKey(const ValueKey('banner-next')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_centerX(tester, '轮播1'), closeTo(first, 2));

    await tester.tap(find.byKey(const ValueKey('banner-prev')), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_centerX(tester, '轮播0'), closeTo(first, 2));
  });

  testWidgets('手指划仍然翻页（安卓那路没被改动碰坏）', (tester) async {
    await tester.pumpWidget(_host(HomeBanner(sheets: _five(), onTap: (_) {}, arrows: true)));
    await tester.pumpAndSettle();
    final slot = _centerX(tester, '轮播0');
    final step = _pageStep(tester);

    await _dragWith(tester, _onCard(tester, '轮播0'), -step * 0.7, PointerDeviceKind.touch);

    expect(_centerX(tester, '轮播1'), closeTo(slot, 2));
  });

  testWidgets('MouseDragScroll 就是那把钥匙：不加就拖不动', (tester) async {
    Widget row({required bool wrapped}) {
      final list = ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 20,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => SizedBox(width: 120, child: Text('格子$i')),
      );
      return SizedBox(
        height: 100,
        child: wrapped ? MouseDragScroll(child: list) : list,
      );
    }

    await tester.pumpWidget(_host(row(wrapped: false)));
    await tester.pumpAndSettle();
    var before = _centerX(tester, '格子3');
    await _mouseDrag(tester, _onCard(tester, '格子1'), -300);
    expect(_centerX(tester, '格子3'), closeTo(before, 0.1), reason: '没包就该拖不动（Flutter 默认不接鼠标拖拽）');

    await tester.pumpWidget(_host(row(wrapped: true)));
    await tester.pumpAndSettle();
    before = _centerX(tester, '格子3');
    await _mouseDrag(tester, _onCard(tester, '格子1'), -300);
    expect(_centerX(tester, '格子3'), isNot(closeTo(before, 20)));
  });
}
