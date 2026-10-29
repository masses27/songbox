import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import 'package:lyric_music/library/roster_store.dart';
import 'package:lyric_music/models/results.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/player/player_service.dart';
import 'package:lyric_music/ui/pages/artist_page.dart';
import 'package:lyric_music/ui/pages/artist_roster_page.dart';
import 'package:lyric_music/util/roster.dart';

/// 造一位歌手。`pic` 一律留空：测试里的 HttpClient 是回 400 的假货，
/// 递个地址进去只会让「图片加载失败」这件事混进断言里。
ArtistInfo _a(String id, String name, {String alias = '', int music = 0, int albums = 0}) =>
    ArtistInfo(
        source: 'wy',
        id: id,
        name: name,
        alias: alias,
        musicSize: music,
        albumSize: albums);

void main() {
  group('名单的字母格子', () {
    test('27 格：A–Z 之后是「其它」，一格 100 位', () {
      expect(rosterLetters.length, 27);
      expect(rosterLetters.first, 'A');
      expect(rosterLetters[25], 'Z');
      expect(rosterLetters.last, rosterOther);
      expect(rosterBucketSize, 100);
      expect(rosterGroupLabel('M'), 'M');
      expect(rosterGroupLabel(rosterOther), '其它');
    });

    test('字母换成接口认的字符码，「其它」是 0', () {
      // 2026-10-29 探针：传字母本身一律 400，`Z` 要写 90。
      expect(rosterInitialCode('A'), '65');
      expect(rosterInitialCode('Z'), '90');
      expect(rosterInitialCode('z'), '90', reason: '小写也该认，别让界面为一个大写函数操心');
      expect(rosterInitialCode(rosterOther), '0');
    });

    test('分组照格子顺序排，「其它」垫底，空掉的格子不占标题', () {
      final groups = rosterGroups({
        rosterOther: [_a('1', '30年前，50年后')],
        'C': [_a('2', '陈奕迅')],
        'A': [_a('3', '艾热')],
        'B': const [],
      });
      expect(groups.map((g) => g.label).toList(), ['A', 'C', '其它']);
      expect(rosterCount(groups), 3);
    });

    test('就地筛词认名字也认别名，大小写与全角都不碍事', () {
      final buckets = {
        'C': [_a('1', '陈奕迅', alias: 'Eason Chan')],
        'L': [_a('2', '林俊杰', alias: 'JJ Lin, Wayne Lim')],
        'Z': [_a('3', '张杰')],
      };
      expect(rosterGroups(buckets, keyword: 'eason').map((g) => g.artists.single.name).toList(),
          ['陈奕迅']);
      expect(rosterGroups(buckets, keyword: 'ＥＡＳＯＮ').length, 1,
          reason: '全角大写也该对上：接口那边是整串匹配，才怕这个');
      expect(rosterGroups(buckets, keyword: ' 林 俊杰 ').length, 1);
      expect(rosterGroups(buckets, keyword: '杰').map((g) => g.label).toList(), ['L', 'Z'],
          reason: '筛出来还得分格摆着，她要知道这两位各在哪一格');
      expect(rosterGroups(buckets, keyword: '').length, 3, reason: '空词就是全摆');
    });

    test('缺哪几格说得出名字，界面上那一行也不含糊', () {
      expect(missingBuckets({'A': [_a('1', '艾热')], 'B': const <ArtistInfo>[]}).length, 26);
      expect(rosterPartialNote(failed: ['Z', rosterOther], loaded: 2600),
          'Z、其它 共 2 格没拉回来 · 屏上是 2600 位');
      expect(rosterProgressNote(done: 9, total: 27, loaded: 900),
          '名单加载中 9/27 · 已上屏 900 位');
    });
  });

  group('一格一格拉', () {
    test('每一格到手就上一屏，不等整批', () async {
      var seen = 0;
      final load = await loadRoster(
        (letter) async => letter == rosterOther ? const [] : [_a(letter, '歌手$letter')],
        onBucket: (letter, artists) => seen += artists.length,
        concurrency: 3,
      );
      expect(load.buckets.length, 26);
      expect(load.failed, [rosterOther]);
      expect(seen, 26, reason: '26 格各自回过屏，不是最后一次性摊开');
    });

    test('砸一次就地再试一次；两次都砸才算缺，缺的按字母序报', () async {
      final calls = <String, int>{};
      final load = await loadRoster((letter) async {
        calls[letter] = (calls[letter] ?? 0) + 1;
        if (letter == 'M') {
          // 第一次砸、第二次成：这一格不该算缺口。
          if (calls[letter] == 1) throw Exception('接口没答话');
          return [_a('m', '毛不易')];
        }
        if (letter == 'Z' || letter == 'B') throw Exception('还是没答话');
        return [_a(letter, '歌手$letter')];
      });
      expect(calls['M'], 2);
      expect(calls['Z'], 2, reason: '只试两次，别把限流那条路撞到底');
      expect(load.failed, ['B', 'Z']);
      expect(load.buckets.containsKey('M'), isTrue);
      expect(load.artistCount, 25);
    });

    test('回空也算没答话：实测每一格都回满 100 位', () async {
      final load = await loadRoster((letter) async => const <ArtistInfo>[]);
      expect(load.buckets, isEmpty);
      expect(load.failed.length, rosterLetters.length);
    });
  });

  group('名单落盘', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('roster'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('存进去再读回来，人名别名与歌数一张不少', () async {
      final store = RosterStore(dir: dir);
      await store.save({
        'C': [_a('1', '陈奕迅', alias: 'Eason Chan', music: 1863, albums: 133)],
        'L': [_a('2', '林俊杰', alias: 'JJ Lin / Wayne Lim', music: 599, albums: 74)],
      });
      final snap = await store.load();
      expect(snap, isNotNull);
      expect(snap!.artistCount, 2);
      expect(snap.fresh(), isTrue, reason: '刚存的那一份，不该被当旧的');
      expect(snap.missingLetters.length, 25);
      final lin = snap.buckets['L']!.single;
      expect(lin.alias, 'JJ Lin / Wayne Lim', reason: '别名拆成列表存、拼回一串读，两头得一样');
      expect(lin.musicSize, 599);
      expect(lin.albumSize, 74);
      expect(snap.buckets['C']!.single.name, '陈奕迅');
    });

    test('超过七天的那一份算旧，界面要重打', () async {
      await RosterStore(dir: dir).save({'A': [_a('1', '艾热')]});
      final f = File('${dir.path}/artists.json');
      final j = await f.readAsString();
      expect(j, contains('"fetchedAt"'));
      // 手工把时间戳挪到八天之前，再看它还新不新。
      final old = DateTime.now().subtract(const Duration(days: 8)).toIso8601String();
      await f.writeAsString(
          j.replaceFirst(RegExp(r'"fetchedAt":"[^"]*"'), '"fetchedAt":"$old"'));
      expect((await RosterStore(dir: dir).load())!.fresh(), isFalse);
    });

    test('文件是半截的就不硬撑：读回 null，让界面去重打', () async {
      File('${dir.path}/artists.json').writeAsStringSync('{"letters":{"A":[{"id":"1","na');
      expect(await RosterStore(dir: dir).load(), isNull);
    });

    test('形状对不上（不是名单那个样子）也读回 null', () async {
      File('${dir.path}/artists.json').writeAsStringSync(jsonEncode({'letters': {'A': '不是列表'}}));
      expect(await RosterStore(dir: dir).load(), isNull);
    });

    test('注入的目录还没建出来时，先建再写', () async {
      final nested = Directory('${dir.path}/roster/deeper');
      expect(await RosterStore(dir: nested).save({'A': [_a('1', '艾热')]}), isNull,
          reason: 'JsonFile 先写 .tmp，会连着把父目录建出来');
      expect(File('${nested.path}/artists.json').existsSync(), isTrue);
    });

    test('一个都不剩的名单不落盘，省得下次点进来是张空屏', () async {
      await RosterStore(dir: dir).save({'A': const <ArtistInfo>[]});
      expect(File('${dir.path}/artists.json').existsSync(), isTrue);
      expect(await RosterStore(dir: dir).load(), isNull,
          reason: '空桶存了也不该读回来当名单');
    });
  });

  group('名单页', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('rosterpage'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// 一格一位的假名单：够把格子、行、索引条都摆出来，又不必真去打野。
    Future<List<ArtistInfo>> fakeRoster(String letter) async {
      if (letter == 'C') return [_a('1', '陈奕迅', alias: 'Eason Chan', music: 1863, albums: 133)];
      if (letter == 'L') return [_a('2', '林俊杰', music: 599)];
      if (letter == rosterOther) return [_a('3', '30年前，50年后')];
      return [_a(letter, '歌手$letter')];
    }

    Future<void> pump(WidgetTester tester,
        {Future<List<ArtistInfo>> Function(String)? fetch}) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = _IdlePlayer();
      addTearDown(player.dispose);
      await tester.pumpWidget(MultiProvider(
        providers: [ChangeNotifierProvider<PlayerService>.value(value: player)],
        child: MaterialApp(
          home: ArtistRosterPage(
            fetch: fetch ?? fakeRoster,
            store: RosterStore(dir: dir),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('满名单上屏：格子标题、人数、名字与别名都在，一行都不溢出', (tester) async {
      await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('共 27 位 · 每个字母前 100 位 · 今天拉的'), findsOneWidget);
      expect(find.text('陈奕迅'), findsOneWidget);
      expect(find.text('Eason Chan · 1863 首歌 · 133 张专辑'), findsOneWidget);
      expect(find.text('C'), findsWidgets);
      // 「其它」垫在 27 格最末，得把列表划到底才看得见。
      await tester.dragUntilVisible(
          find.text('其它'), find.byType(CustomScrollView).first, const Offset(0, -400));
      expect(find.text('30年前，50年后'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点索引条最末那一格，列表真跳到它身上', (tester) async {
      await pump(tester);
      expect(find.text('30年前，50年后'), findsNothing, reason: '还没跳，它就该在屏外');
      final bar = find.byKey(const Key('rosterIndexBar'));
      final size = tester.getSize(bar);
      final at = tester.getTopLeft(bar) + Offset(size.width / 2, size.height - 1);
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(find.text('30年前，50年后'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('就地筛词：命中只留那一格，没命中给出搜歌手与搜歌两条出口', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField).first, '奕迅');
      await tester.pump();
      expect(find.text('筛出 1 位 · 屏上这一份共 27 位'), findsOneWidget);
      expect(find.text('陈奕迅'), findsOneWidget);
      expect(find.text('林俊杰'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '周杰伦');
      await tester.pump();
      expect(find.textContaining('没对上「周杰伦」'), findsOneWidget);
      expect(find.text('搜歌手'), findsOneWidget);
      expect(find.text('在歌里搜这个词'), findsOneWidget);
      expect(find.byType(GestureDetector), findsWidgets, reason: '筛的时候索引条收掉，别留 27 格死按');
    });

    testWidgets('一格也没拉回来时说「没答话」，不说「没有歌手」', (tester) async {
      await pump(tester, fetch: (letter) async => throw Exception('连不上'));
      expect(find.text('名单一格也没拉回来 · 多半是这会儿没网'), findsOneWidget);
      expect(find.text('再拉一遍'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('缺的几格在列表上面那行报出来，还留一颗再拉一遍', (tester) async {
      await pump(tester,
          fetch: (letter) async =>
              letter == 'Z' ? throw Exception('砸了') : [_a(letter, '歌手$letter')]);
      expect(find.text('Z 共 1 格没拉回来 · 屏上是 26 位'), findsOneWidget);
      expect(find.text('再拉一遍缺的那几格'), findsOneWidget);
    });

    testWidgets('点一位歌手进他本人的歌手页', (tester) async {
      await pump(tester);
      await tester.tap(find.text('陈奕迅'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byType(ArtistPage), findsOneWidget);
      // 歌手页一开张就去打接口，把那条在飞的请求收干净，别留定时器给下一个测试。
      await tester.pump(const Duration(seconds: 30));
    });
  });
}

/// 空播放器的假货：名单页只要底下挂着一条播放栏，不需要它真能出声。
class _IdlePlayer extends ChangeNotifier implements PlayerService {
  @override
  final List<Song> queue = [];
  @override
  int index = -1;
  @override
  Song? get current => null;
  @override
  PlayMode playMode = PlayMode.list;
  @override
  String get playModeLabel => playMode.label;
  @override
  IconData get playModeIcon => playMode.icon;
  @override
  bool get busy => false;
  @override
  String? get waitNote => null;
  @override
  bool get isBuffering => false;
  @override
  Duration? get seekHold => null;
  @override
  Duration? get total => null;
  @override
  Stream<PlayerState> get playerStateStream => const Stream<PlayerState>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
