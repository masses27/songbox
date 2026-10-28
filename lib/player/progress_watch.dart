/// 盯进度的一只表：把「屏幕上还写着在放、其实已经不往前走了」认出来。
///
/// 播放器有两种「没动静」是出了名的不自报：
/// 一是播完那一下没回话（桌面那个内核要三条同时对上才把 completed 报上来，
/// 安卓也偶发不回话），队列就停在最后一秒；二是中途断流，它只停在缓冲里，
/// 既不报错也不进 idle。两种都要靠「进度还在不在往前走」判，所以判据得能单独
/// 说清楚，也要能脱离播放器测。
///
/// 判据只有一条：往前走满 [minStep] 才算还在放。末尾那点抖动（几十毫秒、或者
/// 被内核清回零）不能把计时清零 —— 原来正是这里让兜底永远凑不齐几跳，和「每次
/// 重试都把额度重新发满」那个死循环是同一个毛病：判据坐在被它管的那条路上，
/// 一走就被重置。
class ProgressWatch {
  ProgressWatch({
    this.minStep = const Duration(seconds: 1),
    this.endRounds = 3,
    this.starveRounds = 15,
    this.coldStartRounds = 40,
  });

  /// 往前走满这么多才算「还在放」。
  final Duration minStep;

  /// 贴到末尾之后连着几跳没动静，就按「放完了」放行。
  final int endRounds;

  /// 响过之后几跳没动静，按「这条流不再往前给了」收拾。
  final int starveRounds;

  /// 一秒都没响过（起播那一趟正在慢慢缓冲）给更多一点的钟点：桌面版开一条远程
  /// 流先要建连再攒缓冲，本来就比安卓慢，别把还在缓冲的那首当成死的掐掉。
  final int coldStartRounds;

  Duration? _base;
  int _still = 0;

  /// 此刻已经连着几跳没往前走了（只给日志和测试看）。
  int get stillRounds => _still;

  /// 换了一首、或从头重开：重新定基准，别拿上一首末尾的位置判这一首。
  void reset() {
    _base = null;
    _still = 0;
  }

  /// 表跳了一下。[pos] 是最后听到的位置，[finished] 表示它已经贴到这首歌的末尾。
  WatchAction tick(Duration pos, {required bool finished}) {
    final base = _base;
    if (base == null || pos > base + minStep) {
      _base = pos;
      _still = 0;
      return WatchAction.none;
    }
    _still++;
    if (_still < endRounds) return WatchAction.none;
    if (finished) {
      _still = 0;
      return WatchAction.trackEnd;
    }
    if (_still >= (pos > Duration.zero ? starveRounds : coldStartRounds)) {
      _still = 0;
      return WatchAction.starved;
    }
    return WatchAction.none;
  }
}

enum WatchAction {
  /// 还在放，或还没到该插手的钟点。
  none,

  /// 放到头了却没收到播完回执：按「这一首放完了」放行。
  trackEnd,

  /// 中途再没往前走：按断流收拾（等一等再放同一首 → 扔掉这条地址重取 → 报错并往前走）。
  starved,
}

/// 把「这一首最后听到哪儿」拿在手里的这一小块。
///
/// 只认往前走的位置：内核在播完那一下会把 position 清回零（playing 却还留着 true），
/// 跟着它写就等于把「听到 3:58」记成「听到 0:00」——续播会从头放同一首，盯进度的表
/// 也再也认不出这是放到了头。
///
/// 但「只往上走」这一条本身不够：往前走的幅度还得跟墙上时钟对得上。一秒之内冒出
/// 3:58 的那一步不是进度，是脏值（上一条流还没换干净的位置、或者内核报晚了）。
/// 原来这里没有闸，脏值一旦挤进来就再也退不出去，屏幕上于是「永远贴在末尾」，
/// 六秒后按「放完了」切下一首 —— 而她听到的是「只播一点点就自己跳歌」。后台最容易
/// 撞上：装载慢、事件报得稀，起播那一刻手里还攥着上一首末尾的位置正好是这一秒。
class ProgressRatchet {
  ProgressRatchet({
    this.tolerance = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 墙上时钟之外还愿意多给的余量：事件报晚半秒、缓冲一次补进两秒，这些都算正常推进。
  final Duration tolerance;

  final DateTime Function() _clock;

  Duration _value = Duration.zero;

  /// 上一个被认下来的点是什么时候报上来的：往前能走多远，按它算。
  DateTime _at = DateTime.now();

  Duration get value => _value;

  /// 换了一首、拖了进度条、或者单曲循环重开：起点就是这里给的数。
  /// 续播那一趟要带 `resume` 而不是零 —— 不然第一个报上来的 2:13 会被当成
  /// 一步跨了两分钟的脏值挡在门外，往后每一跳都进不来。
  void start(Duration at) {
    _value = at;
    _at = _clock();
  }

  /// 报上来一个点。认下来返回 true；往后退的、一步跨得比时间还多的不收。
  /// [speed] 是倍速：2 倍速下声音真的会比墙上时钟快一倍，不乘上去会把正常推进挡掉。
  bool note(Duration reported, {double speed = 1.0}) {
    if (reported <= _value) return false;
    final now = _clock();
    final allowed = now.difference(_at) * speed + tolerance;
    if (reported - _value > allowed) return false;
    _value = reported;
    _at = now;
    return true;
  }
}
