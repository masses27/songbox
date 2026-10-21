import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/library/library_store.dart';
import 'package:lyric_music/settings/app_settings.dart';
import 'package:lyric_music/util/app_log.dart';
import 'package:lyric_music/util/json_file.dart';
import 'package:lyric_music/util/memo.dart';

void main() {
  group('JsonFile', () {
    late Directory dir;
    late File target;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('jsonfile');
      target = File('${dir.path}/data.json');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('写出去的读得回来', () {
      JsonFile.write(target, {'a': 1, 'list': [1, 2, 3]});
      final back = JsonFile.read(target);
      expect((back as Map)['a'], 1);
      expect(back['list'], [1, 2, 3]);
    });

    test('主文件坏了会从 .bak 恢复，坏文件改名留档', () {
      JsonFile.write(target, {'v': 1});
      JsonFile.write(target, {'v': 2}); // 这次会留下 v=1 的 .bak
      target.writeAsStringSync('{"v": 2, 断掉的 json');
      expect(JsonFile.read(target), {'v': 1});
      expect(target.existsSync(), isFalse, reason: '坏文件要让位，否则下次启动再撞一次');
      final kept = dir.listSync().whereType<File>().where((f) => f.path.contains('.corrupt.'));
      expect(kept.length, 1, reason: '坏内容要留档，不能被悄悄丢掉');
      expect(kept.single.readAsStringSync(), contains('断掉的 json'));
    });

    test('两个文件都读不出时返回 null，不抛异常', () {
      target.writeAsStringSync('not json at all');
      expect(JsonFile.read(target), isNull);
    });

    test('写完不留下 .tmp', () {
      JsonFile.write(target, [1, 2]);
      expect(File('${target.path}.tmp').existsSync(), isFalse);
      expect(jsonDecode(target.readAsStringSync()), [1, 2]);
    });
  });

  group('Memo', () {
    test('第一次调用一定会结束', () async {
      // 曾经 whenComplete 的箭头写法让它等自己，冷调用永远不返回，
      // 界面表现为整屏转圈。这里用 timeout 兜住，卡住就是失败。
      final memo = Memo();
      final v = await memo.run('k', () async => 'v').timeout(const Duration(seconds: 2));
      expect(v, 'v');
    });

    test('命中缓存就不再执行 body', () async {
      final memo = Memo();
      var calls = 0;
      Future<int> body() async => ++calls;
      expect(await memo.run('k', body), 1);
      expect(await memo.run('k', body), 1);
      expect(calls, 1);
    });

    test('失败不缓存，下一次会重试', () async {
      final memo = Memo();
      var calls = 0;
      Future<int> body() {
        calls++;
        return calls == 1 ? Future.error(Exception('boom')) : Future.value(2);
      }

      await expectLater(memo.run('k', body), throwsA(isA<Exception>()));
      expect(await memo.run('k', body), 2);
      expect(calls, 2);
    });

    test('同一 key 的并发请求共享一次执行', () async {
      final memo = Memo();
      var calls = 0;
      Future<int> body() async {
        calls++;
        await Future.delayed(const Duration(milliseconds: 20));
        return calls;
      }

      final results = await Future.wait([memo.run('k', body), memo.run('k', body)]);
      expect(results, [1, 1]);
      expect(calls, 1);
    });

    test('remove 之后重新取', () async {
      final memo = Memo();
      var calls = 0;
      Future<int> body() async => ++calls;
      await memo.run('k', body);
      memo.remove('k');
      expect(await memo.run('k', body), 2);
    });

    test('超过容量时先淘汰最久没用的', () async {
      final memo = Memo(maxEntries: 3);
      for (final k in ['a', 'b', 'c']) {
        await memo.run(k, () async => k);
      }
      await memo.run('a', () async => 'a'); // a 刚用过，b 退到最旧
      await memo.run('d', () async => 'd'); // 挤掉 b
      var probed = 0;
      await memo.run('b', () async {
        probed++;
        return 'b2';
      });
      expect(probed, 1, reason: 'b 应已被淘汰，需要重新计算');
      probed = 0;
      await memo.run('a', () async {
        probed++;
        return 'x';
      });
      expect(probed, 0, reason: 'a 还在缓存里');
    });
  });

  group('QQ 设备号', () {
    test('生成 10 位、首位不为 0，且不抛 RangeError', () {
      // 上一版写的是 `Random.secure().nextInt(9000000000)`：`nextInt` 的上限是 2^32，
      // 那一行每次必抛，她手机上的「检测失败：RangeError (max)…9000000000」就是它。
      for (var i = 0; i < 300; i++) {
        final g = AppSettings.newTxGuid();
        expect(g.length, 10);
        expect(g.startsWith('0'), isFalse);
        expect(int.tryParse(g), isNotNull);
      }
    });

    test('换过的种子也只出 10 位（长度不靠运气）', () {
      for (final seed in [0, 1, 7, 99991]) {
        final g = AppSettings.newTxGuid(Random(seed));
        expect(g.length, 10, reason: 'seed $seed 生成成 ${g.length} 位了');
      }
    });
  });

  group('听歌日志', () {
    // 这一段全程不调 init：日志目录要等 path_provider 回来，而冷启动头几百毫秒
    // 的日志正是攒在内存里那份。攒的下限行为反而是最该钉住的。
    test('目录还没就绪时先攒着，一行都不落在地上', () async {
      AppLog.add('播', '第一条');
      AppLog.add('链', '第二条');
      final t = await AppLog.tail();
      expect(t, contains('[播] 第一条'));
      expect(t.split('\n').last, contains('[链] 第二条'));
      expect(t.split('\n').last, matches(r'^\d\d:\d\d:\d\d '));
    });

    test('攒过头就丢最旧的，别把内存当日志盘', () async {
      for (var i = 0; i < 260; i++) {
        AppLog.write('刷 $i');
      }
      final lines = (await AppLog.tail()).split('\n');
      expect(lines.length, lessThanOrEqualTo(200));
      expect(lines.last, '刷 259');
      expect(lines.first, isNot(contains('第一条')), reason: '满了该丢的是最旧那些');
    });

    test('复制出去的那段开头带着版本和音质', () async {
      final t = await AppLog.exportText();
      expect(t, startsWith('听歌小窝 v${AppSettings.appVersion} · 音质 ${AppSettings.instance.quality}'));
      expect(t, contains('----'));
    });
  });

  group('听歌计数', () {
    test('歌手名和时长存得回去；空的不落盘，不白占位置', () {
      final st = PlayStat(at: 1, plays: 2);
      expect(st.toJson(), {'at': 1, 'plays': 2, 'done': 0, 'heard': 0});
      final full = PlayStat(at: 1, plays: 2, done: 1, heard: 30, singer: '某人', interval: 200);
      final back = PlayStat.fromJson(jsonDecode(jsonEncode(full.toJson())));
      expect(back.singer, '某人', reason: '被挤出最近播放之后，口味只能靠这个名字认人');
      expect(back.interval, 200);
      expect(back.heard, 30);
    });

    test('0.8.23 之前那份只有四个数的记录照样读得回来', () {
      final old = PlayStat.fromJson({'at': 5, 'plays': 1, 'done': 0, 'heard': 0});
      expect(old.at, 5);
      expect(old.singer, '');
      expect(old.interval, 0);
    });
  });
}
