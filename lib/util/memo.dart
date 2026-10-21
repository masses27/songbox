import 'dart:collection';

/// 短周期结果缓存：只缓存成功结果（body 抛异常时什么都不存），用于那些一次要
/// 一两秒、短期内基本不变好的网络调用——目录接口，以及播放链接。
///
/// 条目有上限并按最少使用淘汰：播放链接的键是「歌 × 音质」，不设上限的话
/// 应用开越久占得越多，最后不会崩，只是一路涨。
class Memo {
  Memo({this.ttl = const Duration(minutes: 5), this.maxEntries = 300});

  final Duration ttl;
  final int maxEntries;
  final LinkedHashMap<String, ({DateTime at, Object value})> _store = LinkedHashMap();

  /// 在途调用共享同一个 Future：同一首歌唱片机或列表同时请求时只发一次网络请求。
  final Map<String, Future<Object?>> _pending = {};

  /// 每个键的「代数」。remove/clear 会把它加一代，让那一代之前已经在飞的调用
  /// 回来时不再写回缓存——不然「播放失败后丢掉这条链接」会被晚到的旧结果原地复活。
  final Map<String, int> _gen = {};

  Future<T> run<T>(String key, Future<T> Function() body) async {
    final hit = _store[key];
    if (hit != null && DateTime.now().difference(hit.at) < ttl) {
      _store.remove(key);
      _store[key] = hit; // 挪到队尾，淘汰顺序按「最近用过」而不是「最早写入」
      return hit.value as T;
    }
    final inflight = _pending[key];
    if (inflight != null) return await inflight as T;
    final gen = _gen[key] ?? 0;
    late final Future<Object?> future;
    future = body().then((value) {
      if ((_gen[key] ?? 0) == gen) {
        _store[key] = (at: DateTime.now(), value: value as Object);
        _trim();
      } else {
        _gen.remove(key);
      }
      return value as Object?;
      // 必须是代码块而不是箭头：`whenComplete(() => _pending.remove(key))` 会把
      // remove 的返回值（正是这个 Future 自己）交给 whenComplete，而 whenComplete
      // 会等回调返回的 Future——等于等它自己，第一次调用永远不结束。
    }).whenComplete(() {
      // 只撤自己这一次：中途被 clear 掉、别人又重新发起的那条在途调用不能跟着没了。
      if (identical(_pending[key], future)) _pending.remove(key);
    });
    _pending[key] = future;
    return await future as T;
  }

  /// 丢掉一个键——播放失败后要让下次重试重新取链接。
  void remove(String key) {
    _store.remove(key);
    // 只有确实还在飞的那次需要记账；它回来时代数就被消费掉了，不留常驻条目。
    if (_pending.containsKey(key)) _gen[key] = (_gen[key] ?? 0) + 1;
  }

  void clear() {
    _store.clear();
    for (final k in _pending.keys) {
      _gen[k] = (_gen[k] ?? 0) + 1;
    }
    _pending.clear();
  }

  /// 先清过期的，剩下的还是超上限才按最久未用淘汰。
  void _trim() {
    if (_store.length <= maxEntries) return;
    final now = DateTime.now();
    _store.removeWhere((_, e) => now.difference(e.at) >= ttl);
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}
