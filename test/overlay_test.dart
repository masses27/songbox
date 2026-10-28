import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:lyric_music/library/library_store.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/player/player_service.dart';
import 'package:lyric_music/ui/player/queue_sheet.dart';
import 'package:lyric_music/ui/theme.dart';
import 'package:lyric_music/ui/widgets.dart';

class _QueuePlayer extends ChangeNotifier implements PlayerService {
  @override
  final List<Song> queue = [];
  @override
  int index = -1;
  @override
  PlayMode playMode = PlayMode.list;
  @override
  String get playModeLabel => playMode.label;
  @override
  IconData get playModeIcon => playMode.icon;
  @override
  void cyclePlayMode() {
    playMode = PlayMode.values[(playMode.index + 1) % PlayMode.values.length];
    notifyListeners();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<BuildContext> _host(WidgetTester tester,
    {Size size = const Size(1280, 720), bool dark = true, bool localDark = false,
    double scale = 1, double keyboard = 0, int songCount = 0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final player = _QueuePlayer();
  player.queue.addAll(List.generate(songCount,
      (i) => Song(source: 'wy', songmid: '$i', name: '歌曲 $i', singer: '歌手')));
  addTearDown(player.dispose);
  late BuildContext hostContext;
  Widget content() => Builder(builder: (context) {
        hostContext = context;
        return const SizedBox.expand();
      });
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerService>.value(value: player),
      ChangeNotifierProvider<LibraryStore>.value(value: LibraryStore.instance),
    ],
    child: MaterialApp(
      theme: AppTheme.palette(darkMode: dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: localDark ? Theme(data: AppTheme.palette(darkMode: true), child: content()) : content(),
      ),
    ),
  ));
  return hostContext;
}

void main() {
  test('深浅主题的弹窗都半透明，局部深色不改变全局设置', () {
    final original = AppTheme.dark;
    addTearDown(() => AppTheme.dark = original);
    AppTheme.dark = false;
    for (final dark in [false, true]) {
      final theme = AppTheme.palette(darkMode: dark);
      expect(theme.brightness, dark ? Brightness.dark : Brightness.light);
      for (final color in [theme.dialogTheme.backgroundColor, theme.bottomSheetTheme.modalBackgroundColor,
        theme.popupMenuTheme.color, theme.snackBarTheme.backgroundColor]) {
        expect(color!.a, closeTo(.92, .005));
      }
      expect(theme.dialogTheme.constraints!.maxWidth, 420);
      expect(theme.bottomSheetTheme.constraints!.maxWidth, 560);
      expect(theme.snackBarTheme.backgroundColor!.computeLuminance(), lessThan(.1));
    }
    expect(AppTheme.dark, isFalse);
  });

  for (final dark in [false, true]) {
    testWidgets('桌面对话框限宽、可确认，dark=$dark', (tester) async {
      final context = await _host(tester, size: const Size(1920, 1080), dark: dark);
      final result = confirmAction(context, title: '删除下载', message: '只删除本机下载，不影响歌单。');
      await tester.pumpAndSettle();
      final surface = find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;
      expect(tester.getSize(surface).width, lessThanOrEqualTo(420));
      expect(tester.getSize(surface).height, lessThan(360));
      expect(tester.widget<Material>(surface).color!.a, closeTo(.92, .005));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长提示条限宽且撤销可点，dark=$dark', (tester) async {
      final context = await _host(tester, size: const Size(1920, 1080), dark: dark);
      var undone = false;
      toast(context, '已移除这首歌曲', actionLabel: '撤销', onAction: () => undone = true);
      await tester.pumpAndSettle();
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.width, 480);
      final surface = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first;
      expect(tester.widget<Material>(surface).color!.computeLuminance(), lessThan(.1));
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(undone, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小窗口大字号与键盘弹出时对话框仍可关闭', (tester) async {
    final context = await _host(tester, size: const Size(320, 480), scale: 1.5, keyboard: 180);
    final result = confirmAction(context, title: '清除缓存', message: '保留收藏与歌单。\n' * 12);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('新建歌单输入在窄屏和键盘下可提交', (tester) async {
    final context = await _host(tester, size: const Size(320, 480), keyboard: 180);
    final result = promptText(context, title: '新建歌单', hint: '歌单名称');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '睡前听');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(await result, '睡前听');
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色应用内的深色播放页，弹窗继承局部深色', (tester) async {
    final context = await _host(tester, dark: false, localDark: true);
    final result = confirmAction(context, title: '移除', message: '仅移出当前队列。');
    await tester.pumpAndSettle();
    final surface = find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;
    expect(tester.widget<Material>(surface).color!.computeLuminance(), lessThan(.1));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('歌曲菜单在小窗口大字号下滚动到底，局部深色不冒白底', (tester) async {
    final context = await _host(tester, size: const Size(320, 480), dark: false, localDark: true, scale: 1.5);
    showSongMenu(context, Song(source: 'wy', songmid: 'test', name: '测试歌曲', singer: '歌手'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final sheet = find.byType(BottomSheet);
    expect(tester.getSize(sheet).height, lessThanOrEqualTo(480 * .85));
    final surface = find.descendant(of: sheet, matching: find.byType(Material)).first;
    expect(tester.widget<Material>(surface).color!.computeLuminance(), lessThan(.1));
    await tester.dragUntilVisible(find.text('下载'), find.byType(SingleChildScrollView), const Offset(0, -180));
    expect(find.text('下载').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有歌曲时队列可拖高与滚动，窄屏大字号标题仍放得下', (tester) async {
    final context = await _host(tester, size: const Size(320, 480), scale: 1.5, songCount: 30);
    showPlayQueue(context);
    await tester.pumpAndSettle();
    final surface = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first;
    final initialHeight = tester.getSize(surface).height;
    expect(find.text('清空').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ReorderableListView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface).height, greaterThan(initialHeight));
    expect(tester.getSize(surface).height, lessThanOrEqualTo(480 * .85));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 480), const Size(1920, 1080)]) {
    testWidgets('播放队列不撑满窗口，可展开并切模式 $size', (tester) async {
      final context = await _host(tester, size: size, scale: 1.5, dark: false, localDark: true);
      showPlayQueue(context);
      await tester.pumpAndSettle();
      final sheet = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first;
      expect(tester.getSize(sheet).width, lessThanOrEqualTo(560));
      expect(tester.getSize(sheet).height, lessThan(size.height * .85));
      expect(find.text('队列是空的'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('列表循环'));
      await tester.pumpAndSettle();
      expect(find.text('单曲循环'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
