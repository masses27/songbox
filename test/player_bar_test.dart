import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/player/player_service.dart';
import 'package:lyric_music/settings/app_settings.dart';
import 'package:lyric_music/ui/player/player_bar.dart';

class _FakePlayerService extends ChangeNotifier implements PlayerService {
  final PlayerService service = PlayerService.instance;
  final states = StreamController<PlayerState>.broadcast();
  final Stream<Duration> positions = Stream.value(const Duration(seconds: 30));
  bool playing = true;
  int previousCalls = 0;
  int nextCalls = 0;
  int toggleCalls = 0;
  int playCalls = 0;

  _FakePlayerService() {
    service.addListener(notifyListeners);
  }

  @override
  List<Song> get queue => service.queue;
  @override
  int get index => service.index;
  @override
  Song? get current => service.current;
  @override
  PlayMode get playMode => service.playMode;
  @override
  String get playModeLabel => service.playModeLabel;
  @override
  IconData get playModeIcon => service.playModeIcon;
  @override
  bool get busy => false;
  @override
  String? get waitNote => null;
  bool buffering = false;
  @override
  bool get isBuffering => buffering;
  @override
  Duration? get seekHold => null;
  @override
  Duration get total => const Duration(minutes: 4);
  @override
  Stream<Duration> get positionStream => positions;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;

  @override
  void setPlayMode(PlayMode mode) => service.setPlayMode(mode);
  @override
  void cyclePlayMode() => service.cyclePlayMode();

  @override
  Future<void> previous() async {
    previousCalls++;
  }

  @override
  Future<void> next({bool manual = true}) async {
    nextCalls++;
  }

  @override
  Future<void> togglePlay() async {
    toggleCalls++;
    playing = !playing;
    states.add(PlayerState(playing, ProcessingState.ready));
  }

  @override
  Future<void> playAt(int i, {bool deepWarm = false}) async {
    playCalls++;
  }

  @override
  Future<void> playList(List<Song> songs, int start) async {
    playCalls++;
  }

  @override
  void dispose() {
    service.removeListener(notifyListeners);
    states.close();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpBar(WidgetTester tester, _FakePlayerService player,
    {double width = 600, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<PlayerService>.value(
    value: player,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: const Scaffold(bottomNavigationBar: PlayerBar()),
    ),
  ));
  player.states.add(PlayerState(player.playing, ProcessingState.ready));
  await tester.pumpAndSettle();
}

void main() {
  final service = PlayerService.instance;
  final settings = AppSettings.instance;

  setUp(() {
    final queue = List<Song>.of(service.queue);
    final index = service.index;
    final mode = service.playMode;
    final savedMode = settings.playMode;
    addTearDown(() {
      service.queue
        ..clear()
        ..addAll(queue);
      service.index = index;
      service.playMode = mode;
      settings.playMode = savedMode;
    });
    service.queue
      ..clear()
      ..addAll([
        Song(source: 'wy', songmid: '1', name: '这是一首很长很长的歌曲名称需要完整保留但显示时省略',
            singer: '这是一串很长的歌手名字和合唱署名', interval: 240),
        Song(source: 'wy', songmid: '2', name: '另一首歌', singer: '另一位歌手', interval: 180),
      ]);
    service.index = 0;
    service.playMode = PlayMode.list;
    settings.playMode = PlayMode.list.name;
  });

  test('直接选择与循环切换共用设置保存入口，不动曲目和队列', () {
    final queue = List<Song>.of(service.queue);
    final current = service.current;
    var notifications = 0;
    var saved = 0;
    void onChanged() => notifications++;
    void onSaved() => saved++;
    service.addListener(onChanged);
    settings.addListener(onSaved);
    addTearDown(() {
      service.removeListener(onChanged);
      settings.removeListener(onSaved);
    });

    service.setPlayMode(PlayMode.random);
    expect(service.playMode, PlayMode.random);
    expect(settings.playMode, 'random');
    expect(notifications, 1);
    expect(saved, 1);
    service.setPlayMode(PlayMode.random);
    expect(notifications, 1);
    expect(saved, 1);

    for (final mode in [PlayMode.none, PlayMode.list, PlayMode.single, PlayMode.random]) {
      service.cyclePlayMode();
      expect(service.playMode, mode);
      expect(settings.playMode, mode.name);
      expect(service.playModeLabel, mode.label);
      expect(service.playModeIcon, mode.icon);
      expect(service.current, same(current));
      expect(service.index, 0);
      expect(service.queue, orderedEquals(queue));
    }
    expect(notifications, 5);
    expect(saved, 5);
  });

  testWidgets('无当前曲目时隐藏整个播放条', (tester) async {
    service.index = -1;
    final player = _FakePlayerService();
    addTearDown(player.dispose);
    await _pumpBar(tester, player, width: 320);
    expect(find.byType(PopupMenuButton<PlayMode>), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(tester.getSize(find.byType(PlayerBar)).height, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单可直选全部模式，同步当前图标且不重新播放', (tester) async {
    final player = _FakePlayerService();
    addTearDown(player.dispose);
    final queue = List<Song>.of(player.queue);
    final song = player.current;
    await _pumpBar(tester, player);
    expect(find.byTooltip('列表循环'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);

    for (final mode in [PlayMode.random, PlayMode.single, PlayMode.none, PlayMode.list]) {
      await tester.tap(find.byType(PopupMenuButton<PlayMode>));
      await tester.pumpAndSettle();
      for (final label in ['列表循环', '单曲循环', '随机播放', '播完停止']) {
        expect(find.text(label), findsOneWidget);
      }
      final items = tester.widgetList<CheckedPopupMenuItem<PlayMode>>(
          find.byType(CheckedPopupMenuItem<PlayMode>));
      expect(items.singleWhere((item) => item.checked).value, player.playMode);
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<PlayMode>, mode.label));
      await tester.pumpAndSettle();
      expect(player.playMode, mode);
      expect(settings.playMode, mode.name);
      expect(find.byTooltip(mode.label), findsOneWidget);
      expect(find.descendant(of: find.byType(PopupMenuButton<PlayMode>), matching: find.byIcon(mode.icon)),
          findsOneWidget);
      expect(player.current, same(song));
      expect(player.index, 0);
      expect(player.queue, orderedEquals(queue));
      expect(player.playing, isTrue);
      expect(find.byTooltip('暂停'), findsOneWidget);
      expect(player.playCalls + player.previousCalls + player.nextCalls + player.toggleCalls, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('其他入口切换后菜单同步，取消菜单不改变模式', (tester) async {
    final player = _FakePlayerService();
    addTearDown(player.dispose);
    await _pumpBar(tester, player);
    service.cyclePlayMode();
    await tester.pumpAndSettle();
    expect(find.byTooltip('单曲循环'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<PlayMode>));
    await tester.pumpAndSettle();
    final items = tester.widgetList<CheckedPopupMenuItem<PlayMode>>(
        find.byType(CheckedPopupMenuItem<PlayMode>));
    expect(items.singleWhere((item) => item.checked).value, PlayMode.single);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(CheckedPopupMenuItem<PlayMode>), findsNothing);
    expect(player.playMode, PlayMode.single);
    expect(player.playCalls + player.toggleCalls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 360.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('$width 窄屏长歌名及 $scale 倍字体不溢出，模式与切歌按钮可点', (tester) async {
        final player = _FakePlayerService();
        addTearDown(player.dispose);
        await _pumpBar(tester, player, width: width, scale: scale);
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(PlayerBar));
        final title = find.text(player.current!.name);
        expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
        expect(tester.widget<Text>(title).maxLines, 1);
        expect(tester.getRect(title).right, lessThanOrEqualTo(bar.right));
        expect(tester.getSize(title).width, greaterThan(200));
        for (final label in ['列表循环', '上一首', '暂停', '下一首', '播放队列']) {
          final button = find.byTooltip(label);
          expect(button.hitTestable(), findsOneWidget);
          final rect = tester.getRect(button);
          expect(rect.left, greaterThanOrEqualTo(bar.left));
          expect(rect.right, lessThanOrEqualTo(bar.right));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        await tester.tap(find.byTooltip('上一首'));
        await tester.tap(find.byTooltip('下一首'));
        await tester.tap(find.byTooltip('暂停'));
        await tester.pumpAndSettle();
        expect(player.previousCalls, 1);
        expect(player.nextCalls, 1);
        expect(player.toggleCalls, 1);
        expect(find.byTooltip('播放'), findsOneWidget);
        await tester.tap(find.byType(PopupMenuButton<PlayMode>));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(CheckedPopupMenuItem<PlayMode>, '随机播放'));
        await tester.pumpAndSettle();
        expect(player.playMode, PlayMode.random);
        expect(player.playing, isFalse);
        expect(player.playCalls, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('窄屏仍能打开播放队列', (tester) async {
    final player = _FakePlayerService();
    addTearDown(player.dispose);
    await _pumpBar(tester, player, width: 360);
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    expect(find.text('播放队列 · 2 首'), findsOneWidget);
    expect(player.playCalls + player.toggleCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓冲时这一行改成「在缓冲…」，通了就回到歌手名', (tester) async {
    final player = _FakePlayerService();
    addTearDown(player.dispose);
    await _pumpBar(tester, player);
    expect(find.text(player.current!.singer), findsOneWidget);
    player.buffering = true;
    player.states.add(PlayerState(true, ProcessingState.buffering));
    await tester.pumpAndSettle();
    expect(find.text('在缓冲…'), findsOneWidget);
    expect(find.text(player.current!.singer), findsNothing);
    player.buffering = false;
    player.states.add(PlayerState(true, ProcessingState.ready));
    await tester.pumpAndSettle();
    expect(find.text('在缓冲…'), findsNothing);
    expect(find.text(player.current!.singer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
