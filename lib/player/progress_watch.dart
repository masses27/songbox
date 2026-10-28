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

  /// 中途再没往前走：按断流收拾（重取一条地址 → 等一等重试 → 报错并往前走）。
  starved,
}
