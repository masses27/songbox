/// 冷启动那几块互不相干的存储（设置、曲库、日志）里哪一块没起来。
///
/// 原来这几个 init 直接 `Future.wait` 在一起，一个抛异常整批没人接 ——
/// 结果就是「收藏是空的、日志是空的」这种最容易被当成 App 坏了的现象，
/// 而日志里一行线索都没有，因为她那边根本没走到记日志那一步。
/// 现在每一块自己接住自己的失败，攒在这儿，主壳在第一帧之后一次性告诉她，
/// 并把「看日志」的按钮直接放在提示条上。
class BootFailures {
  BootFailures._();

  static final List<String> _all = [];

  static void add(String what) {
    if (!_all.contains(what)) _all.add(what);
  }

  static bool get hasAny => _all.isNotEmpty;
  static List<String> get all => List.unmodifiable(_all);

  /// 取走那一份并清空：提示只弹一遍，别每次回首页都再打扰她。
  /// 明细已经逐条写进日志了，要看随时能从「日志」那一页翻出来。
  static List<String> drain() {
    final out = List<String>.from(_all);
    _all.clear();
    return out;
  }
}
