/// 「连不上就等一等再试」那一串等待的记账本。
///
/// 单独收成一小块是踩过坑的结果：这笔账原来是播放器上的一个整数，而把它清零的那两行
/// 恰好写在重试自己走的通路上 —— 装载成功一次清一回，没有续播位置的那趟起播也清一回。
/// 于是每一轮重试都先把额度重新发满，5/15/30/60 永远走不到头，一首放不出来的歌能被
/// 同一次失败拖着重试到天亮；她看到的就是「后台挂着不切下一首，只会这一首循环」。
/// 收进对象之后，能重新发满额度的只剩三件事：换了一首歌、这一首真连着放出去够久没再断、
/// 以及她自己按了重试。
class RetryBudget {
  RetryBudget(
    this.delays, {
    this.refillAfter = const Duration(seconds: 90),
  });

  /// 逐次拉长的等待秒数。取用完就该认输 —— 由调用方走原来的路（换源 / 跳下一首）。
  final List<int> delays;

  /// 连续播出这么多秒才认定「网络真回来了」，把额度重新发满。
  final Duration refillAfter;

  /// 这笔账记在哪一首上：同一个键绕回来的是「重试原地再来一趟」，不发新额度。
  String? _songKey;
  int _used = 0;
  Duration _healthy = Duration.zero;

  /// 这一首已经等过几轮了（从 1 数起，日志和播放条那句话都读它）。
  int get used => _used;

  bool get exhausted => _used >= delays.length;

  /// 一轮播放开始：换歌才重新发满，还是原来那一首就接着上一轮的账走。
  void startSong(String songKey) {
    if (_songKey == songKey) return;
    _songKey = songKey;
    refill();
  }

  /// 取走一轮等待。取光了返回 null，调用方必须认输，不然就回到那个死循环里去。
  int? take() {
    if (exhausted) return null;
    // 刚等过一轮，健康计时从头算：攒够的是「这一首连着放出去的秒数」，
    // 断一次就得清零，不然一首歌反复断也能慢慢把额度攒回来。
    _healthy = Duration.zero;
    return delays[_used++];
  }

  /// 正常播出去多少攒多少，攒够 [refillAfter] 才认定网络真回来了，把额度发满。
  /// 「这一次装载成功了」不算：装上了两秒就断，等于没回来。返回 true 表示刚发满。
  /// 倒着走和一步跨很远也不算：那是切歌和拖进度条，不是网络变好了。
  bool notePlayed(Duration delta) {
    if (_used == 0) return false;
    if (delta <= Duration.zero || delta > _maxTick) return false;
    _healthy += delta;
    if (_healthy < refillAfter) return false;
    refill();
    return true;
  }

  /// 重新发满一轮额度。她自己按了「重试」时走这里：那几轮等待是给「没人看着时
  /// 网断了」留的，人回来主动要一次，就该再给一次完整的机会。
  void refill() {
    _used = 0;
    _healthy = Duration.zero;
  }

  /// 队列清了、人彻底换了一批歌：这笔账整个作废。
  void reset() {
    _songKey = null;
    refill();
  }

  /// 位置流一秒一跳是常态，偶尔漏一格；比这还大的一步不是正常推进。
  static const _maxTick = Duration(seconds: 3);
}
