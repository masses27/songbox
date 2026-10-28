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
}
