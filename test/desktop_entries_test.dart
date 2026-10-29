// 桌面版补出来的那两类入口，在手机上必须是「不画、也不抢手势」的。
//
// 0.8.44–0.8.46 那几轮把「只有手势才够得着」的功能在 Windows 上各补了一颗真按得动的
// 键（AppBar 右上角的刷新、右键出菜单）。这两样在手机上要完全隐身：手机上下拉本来就在，
// 长按也顺手，多一颗键只是噪声。两个方向都得钉，而测试跑在本机（Windows）上默认只会走
// 桌面那一条，所以这里用 [desktopUiOverrideForTest] 把两边都摆出来。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/ui/widgets.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

/// [RightTap] 在桌面上加的那一层。整棵树里只有它会挂手型光标（Scaffold、InkWell
/// 自己那些是 basic），所以拿它当「这层包装在不在」的判据。
final _handCursor = find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.click);

void main() {
  tearDown(() => desktopUiOverrideForTest = null);

  group('桌面版', () {
    setUp(() => desktopUiOverrideForTest = true);

    testWidgets('刷新键画得出来，忙的时候按不动', (tester) async {
      var taps = 0;
      final key = find.byKey(const ValueKey('desktop-refresh'));
      await tester.pumpWidget(_host(DesktopRefreshButton(onRefresh: () async => taps++)));
      expect(key, findsOneWidget);
      await tester.tap(key);
      expect(taps, 1);

      await tester.pumpWidget(_host(DesktopRefreshButton(onRefresh: () async => taps++, busy: true)));
      expect(tester.widget<IconButton>(key).onPressed, isNull);
      await tester.tap(key);
      expect(taps, 1);
    });

    testWidgets('右键就是长按那同一件事', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(RightTap(
        onRightTap: () => opened++,
        child: const SizedBox(width: 120, height: 60, child: Center(child: Text('这首歌'))),
      )));
      await tester.tapAt(tester.getCenter(find.text('这首歌')), buttons: kSecondaryButton);
      await tester.pump();
      expect(opened, 1);
      // 光标也换成手型：桌面上「这块能不能点」原本只能试。
      expect(_handCursor, findsOneWidget);
    });
  });

  group('手机上', () {
    setUp(() => desktopUiOverrideForTest = false);

    testWidgets('那颗刷新键不占一格', (tester) async {
      await tester.pumpWidget(_host(DesktopRefreshButton(onRefresh: () async {})));
      expect(find.byKey(const ValueKey('desktop-refresh')), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('右键包装不改变子树，长按照旧', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(RightTap(
        onRightTap: () => opened++,
        child: GestureDetector(
          onLongPress: () => opened += 10,
          behavior: HitTestBehavior.opaque,
          child: const SizedBox(width: 120, height: 60, child: Center(child: Text('这首歌'))),
        ),
      )));
      // 手机那一条分支返回的就是 child 本身：不多一层包装，也就不改光标。
      expect(_handCursor, findsNothing);
      await tester.longPress(find.text('这首歌'));
      await tester.pump();
      expect(opened, 10);
    });
  });
}
