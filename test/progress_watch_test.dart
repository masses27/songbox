import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/player/progress_watch.dart';

// 挂后台「不切下一首，只会这一首循环」的第二半：播完的回执和「其实已经不再往前
// 给了」这两件事，播放器不一定主动报，只能自己盯进度。判据原来直接写在播放器的
// 定时器里，末尾那点抖动会把计时一直清零 —— 兜底于是永远凑不齐那几跳，正是
// 「判据坐在被它管的那条路上」的老毛病。这块把规矩钉死：往前走满一秒才算还在放。
void main() {
  group('ProgressWatch', () {
    test('正常推进：每一跳都往前走满两秒，一次也不插手', () {
      final w = ProgressWatch();
      for (var i = 0; i < 60; i++) {
        expect(w.tick(Duration(seconds: i * 2), finished: false), WatchAction.none);
      }
      expect(w.stillRounds, 0);
    });

    test('末尾那点抖动不算推进：贴到末尾三跳就按放完放行', () {
      final w = ProgressWatch();
      final end = const Duration(minutes: 4);
      expect(w.tick(end, finished: true), WatchAction.none);
      // 内核在末尾来回吐几十毫秒，原来正是这里让兜底永远凑不齐几跳。
      expect(w.tick(end + const Duration(milliseconds: 40), finished: true), WatchAction.none);
      expect(w.tick(end + const Duration(milliseconds: 90), finished: true), WatchAction.none);
      expect(w.tick(end + const Duration(milliseconds: 120), finished: true), WatchAction.trackEnd);
    });

    test('放行那一下计时清零：不会连着把队列推两格', () {
      final w = ProgressWatch();
      final end = const Duration(minutes: 4);
      expect(w.tick(end, finished: true), WatchAction.none); // 定基准
      expect(w.tick(end, finished: true), WatchAction.none);
      expect(w.tick(end, finished: true), WatchAction.none);
      expect(w.tick(end, finished: true), WatchAction.trackEnd);
      expect(w.tick(end, finished: true), WatchAction.none);
      expect(w.tick(end, finished: true), WatchAction.none);
      expect(w.tick(end, finished: true), WatchAction.trackEnd);
    });

    test('只前进一秒不算走满（要的是「超过」一秒）', () {
      final w = ProgressWatch();
      expect(w.tick(const Duration(seconds: 10), finished: false), WatchAction.none);
      expect(w.tick(const Duration(seconds: 11), finished: false), WatchAction.none);
      expect(w.stillRounds, 1);
      expect(w.tick(const Duration(seconds: 13), finished: false), WatchAction.none);
      expect(w.stillRounds, 0);
    });

    test('中途停住：响过的歌 15 跳按断流收拾', () {
      final w = ProgressWatch();
      final at = const Duration(seconds: 80);
      expect(w.tick(at, finished: false), WatchAction.none);
      for (var i = 1; i < 15; i++) {
        expect(w.tick(at, finished: false), WatchAction.none, reason: '第 $i 跳就插手太急');
      }
      expect(w.tick(at, finished: false), WatchAction.starved);
    });

    test('一秒都没响过的多给钟点：按冷启动那一档才插手', () {
      final w = ProgressWatch();
      expect(w.tick(Duration.zero, finished: false), WatchAction.none);
      for (var i = 1; i < 40; i++) {
        // 早就过了「响过的歌」那一档，可这一首一秒都还没响过，不该掐它。
        expect(w.tick(Duration.zero, finished: false), WatchAction.none, reason: '第 $i 跳');
      }
      expect(w.tick(Duration.zero, finished: false), WatchAction.starved);
    });

    test('贴到末尾时不走断流那一档：一路交给播完放行', () {
      final w = ProgressWatch();
      final end = const Duration(minutes: 3);
      expect(w.tick(end, finished: true), WatchAction.none);
      for (var i = 0; i < 45; i++) {
        expect(w.tick(end, finished: true), i % 3 == 2 ? WatchAction.trackEnd : WatchAction.none);
      }
    });

    test('换一首重新定基准：上一首末尾的位置判不了这一首', () {
      final w = ProgressWatch();
      final end = const Duration(minutes: 4);
      w.tick(end, finished: true);
      w.tick(end, finished: true);
      w.reset();
      expect(w.stillRounds, 0);
      // 新的一首从 0:00 起：这一跳只是定基准，不该背着上一首的账。
      expect(w.tick(Duration.zero, finished: false), WatchAction.none);
      expect(w.stillRounds, 0);
      expect(w.tick(Duration.zero, finished: false), WatchAction.none);
      expect(w.stillRounds, 1);
    });

    test('位置倒回去不重新计时：拖进度条那一趟由 seek() 重新定基准', () {
      final w = ProgressWatch();
      expect(w.tick(const Duration(seconds: 100), finished: false), WatchAction.none);
      // 播放器自己报回一个更早的点（不是她拖的）：那不能当成「还在放」的证据。
      for (var i = 0; i < 3; i++) {
        expect(w.tick(const Duration(seconds: 20), finished: false), WatchAction.none);
      }
      expect(w.stillRounds, 3);
    });

    test('门槛可以按需要调', () {
      final w = ProgressWatch(
          minStep: const Duration(seconds: 5), endRounds: 2, starveRounds: 3, coldStartRounds: 6);
      expect(w.tick(const Duration(seconds: 30), finished: false), WatchAction.none);
      expect(w.tick(const Duration(seconds: 34), finished: false), WatchAction.none);
      expect(w.tick(const Duration(seconds: 34), finished: false), WatchAction.none,
          reason: '4 秒没走满 5 秒，可也数到了 endRounds，末尾之外还不能动手');
      expect(w.tick(const Duration(seconds: 34), finished: false), WatchAction.starved);
    });
  });

  // 「听到哪儿」那只表的另一半：挡住脏值。挂后台时装载慢、事件报得稀，起播那一刻
  // 手里还攥着上一首末尾的位置正是最挤不干净的时机 —— 脏值进来退不出去，往后每一首
  // 都贴着末尾，六秒一跳就把队列推走（转述出来是「只播一点点就自己跳歌」）。
  group('ProgressRatchet', () {
    // 一格一格拨的钟：往前走多少算合理，量的就是墙上时钟过了多久。
    (DateTime Function(), void Function(Duration)) clock([DateTime? from]) {
      var now = from ?? DateTime(2026, 1, 1, 12);
      return (() => now, (d) => now = now.add(d));
    }

    test('正常推进：一秒一格全都认', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(Duration.zero);
      for (var i = 1; i <= 60; i++) {
        advance(const Duration(seconds: 1));
        expect(r.note(Duration(seconds: i)), isTrue, reason: '第 $i 秒');
      }
      expect(r.value, const Duration(seconds: 60));
    });

    test('一秒之内冒出末尾的位置不收：那是脏值，不是进度', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(Duration.zero);
      advance(const Duration(milliseconds: 300));
      expect(r.note(const Duration(seconds: 238)), isFalse, reason: '0:00 起半秒里跳到 3:58');
      expect(r.value, Duration.zero);
      // 更要紧的是别把表钉死：真实位置还在往前，下一跳就该进得来。
      advance(const Duration(seconds: 1));
      expect(r.note(const Duration(seconds: 1)), isTrue);
      advance(const Duration(seconds: 1));
      expect(r.note(const Duration(seconds: 2)), isTrue);
      expect(r.value, const Duration(seconds: 2));
    });

    test('往后退的不收，值留着：内核在播完那一下会把位置清回零', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(const Duration(seconds: 235));
      advance(const Duration(seconds: 1));
      expect(r.note(Duration.zero), isFalse);
      expect(r.value, const Duration(seconds: 235));
    });

    test('暂停一分钟再放那一大步认：走得慢是墙上时钟真的过了这么久', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(const Duration(seconds: 40));
      // 暂停期间没有位置流进来，钟照走不误。
      advance(const Duration(minutes: 1));
      expect(r.note(const Duration(seconds: 100)), isTrue);
    });

    test('倍速下声音比墙上时钟快，那一截不能当脏值挡掉', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(const Duration(seconds: 10));
      advance(const Duration(seconds: 2));
      expect(r.note(const Duration(seconds: 14), speed: 2.0), isTrue);
      // 同样这一步按 1 倍速就是跨了 4 秒（墙外只有 2 秒 + 3 秒余量），该认；
      // 跨 10 秒的那种才拦：2 倍速下墙上过 2 秒最多走到 14 秒。
      expect(r.note(const Duration(seconds: 24), speed: 2.0), isFalse);
    });

    test('续播那一趟的起点是 resume：从 0 起算会把 2:13 一路挡在门外', () {
      final (now, advance) = clock();
      final r = ProgressRatchet(clock: now);
      r.start(const Duration(seconds: 133));
      advance(const Duration(seconds: 2));
      expect(r.note(const Duration(seconds: 135)), isTrue);
      expect(r.value, const Duration(seconds: 135));

      // 对照：把起点写成 0 会怎样（这就是原来那一句的毛病）。
      final bad = ProgressRatchet(clock: now);
      bad.start(Duration.zero);
      expect(bad.note(const Duration(seconds: 135)), isFalse);
    });
  });
}
