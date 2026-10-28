import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/player/retry_budget.dart';

// 「等一等再试」那笔账原来散在播放器的两个整数上，而清零的两行正好压在重试自己走的
// 通路上 —— 一首放不出来的歌因此能被拖着重试到天亮。她桌面版那天下午的日志就是账本：
// 「第 1 次重连」670 条（15:03 一直到 19:57，每 20 秒一条），「第 2 次」一条都没有。
// 这块把规矩钉死：只有换歌、连续播出够久、或她自己按了重试，才重新发满额度。
const _delays = [5, 15, 30, 60];
const _one = 'wy:1';
const _two = 'wy:2';

void main() {
  RetryBudget fresh() {
    final b = RetryBudget(_delays);
    b.startSong(_one);
    return b;
  }

  test('同一首绕回来只发一轮额度，取完就认输', () {
    final b = fresh();
    expect(b.take(), 5);
    // 重试走的是「原地再来一趟」，中间哪怕装载成功过，也不该把额度发回去。
    b.startSong(_one);
    expect(b.take(), 15);
    b.startSong(_one);
    expect(b.take(), 30);
    b.startSong(_one);
    expect(b.take(), 60);
    expect(b.take(), isNull);
    expect(b.exhausted, isTrue);
    expect(b.used, 4);
  });

  test('换了一首歌才重新发满：上一首烧光不该判死这一首', () {
    final b = fresh();
    for (var i = 0; i < _delays.length; i++) {
      expect(b.take(), isNotNull);
    }
    expect(b.take(), isNull);
    b.startSong(_two);
    expect(b.take(), 5);
    expect(b.used, 1);
  });

  test('连续播出够久才算网络回来，装载成功本身不算', () {
    final b = fresh();
    expect(b.take(), 5);
    // 一次跳一整段（切歌、拖进度条）不算推进。
    for (var i = 0; i < 40; i++) {
      expect(b.notePlayed(const Duration(seconds: 9)), isFalse);
    }
    expect(b.used, 1);
    // 一秒一格攒到 90 秒才发满。
    var refilled = false;
    for (var i = 0; i < 90 && !refilled; i++) {
      refilled = b.notePlayed(const Duration(seconds: 1));
    }
    expect(refilled, isTrue);
    expect(b.used, 0);
    expect(b.take(), 5);
  });

  test('断一次就把健康计时清零，不能慢慢攒回额度', () {
    final b = fresh();
    expect(b.take(), 5);
    for (var i = 0; i < 80; i++) {
      b.notePlayed(const Duration(seconds: 1));
    }
    expect(b.used, 1); // 还差 10 秒，没发满
    expect(b.take(), 15); // 又等了一轮，计时从头
    for (var i = 0; i < 80; i++) {
      b.notePlayed(const Duration(seconds: 1));
    }
    expect(b.used, 2);
  });

  test('倒着走和原地不动都不算播出过', () {
    final b = fresh();
    expect(b.take(), 5);
    for (var i = 0; i < 200; i++) {
      expect(b.notePlayed(const Duration(seconds: -1)), isFalse);
      expect(b.notePlayed(Duration.zero), isFalse);
    }
    expect(b.used, 1);
  });

  test('没等过任何一轮时不攒健康时长', () {
    final b = RetryBudget(_delays);
    b.startSong(_one);
    for (var i = 0; i < 200; i++) {
      expect(b.notePlayed(const Duration(seconds: 1)), isFalse);
    }
    expect(b.used, 0);
    expect(b.take(), 5);
  });

  test('发满的门槛可以按需要调（默认认「连续播出 90 秒」）', () {
    final b = RetryBudget(_delays, refillAfter: const Duration(seconds: 10));
    b.startSong(_one);
    expect(b.take(), 5);
    // 一步跨太远的不算正常推进，所以三秒三秒地攒。
    for (var i = 0; i < 3; i++) {
      expect(b.notePlayed(const Duration(seconds: 3)), isFalse);
    }
    expect(b.used, 1); // 9 秒，还差一点
    expect(b.notePlayed(const Duration(seconds: 1)), isTrue);
    expect(b.used, 0);
    expect(b.refillAfter, const Duration(seconds: 10));
  });

  test('她按重试是重新给一轮完整机会', () {
    final b = fresh();
    for (var i = 0; i < _delays.length; i++) {
      expect(b.take(), isNotNull);
    }
    expect(b.take(), isNull);
    b.refill();
    expect(b.exhausted, isFalse);
    expect(b.take(), 5);
  });

  test('队列清空后这笔账整个作废', () {
    final b = fresh();
    expect(b.take(), 5);
    b.reset();
    expect(b.used, 0);
    // 清完连同一首也能重新拿满额度：旧队列的账不该带到新一批歌上。
    b.startSong(_one);
    expect(b.take(), 5);
  });
}
