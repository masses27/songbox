import 'dart:math' show pow;

import '../models/song.dart';

/// 本地口味。
///
/// 这个 App 没有任何平台账号，也拿不到平台的推荐 cookie（0.8.20 起登录全部删掉了），
/// 所以「照她的听歌习惯推荐」只可能由本机听出来的东西算：收藏、自建歌单、
/// 每首歌播过几次、听完过几次、最后听到第几秒、什么时候听的。
///
/// 算法刻意保持一眼看完：加权求和 + 半衰期，不做协同过滤。一部手机上的历史只有
/// 几百条，再复杂一点的东西就先开始猜了。
class Taste {
  /// 归一化之后的歌手名 -> 口味权重。
  final Map<String, double> artists;

  /// 专辑名 -> 权重。比歌手弱一档：反复听整张专辑才值得单独记。
  final Map<String, double> albums;

  /// 已经听得很熟、不该再端上来的歌（`source:songmid`）。
  final Set<String> wornOut;

  /// 这几天刚听过的歌。私荐要的是「没听过的像她的歌」，昨天刚放过一遍的这首
  /// 今天再端上来，在她眼里就是推荐没在动。
  final Set<String> heardRecently;

  /// 归一化名 -> 她曲库里出现过的那个子样（`Adele` 而不是 `adele`）。只用来把
  /// 「按谁挑的」这句话写在界面上：匹配要忽略大小写，展示不能。
  final Map<String, String> display;

  const Taste(
      {required this.artists,
      required this.albums,
      required this.wornOut,
      this.heardRecently = const {},
      this.display = const {}});

  static const empty = Taste(artists: {}, albums: {}, wornOut: {});

  bool get isEmpty => artists.isEmpty;

  static String keyOf(Song s) => '${s.source}:${s.songmid}';

  /// 一首歌的歌手可能写成「陈奕迅」，也可能是「王力宏、张靓颖」或「周杰伦 / 费玉清」。
  /// 拆开记，每个署名都算一份：合起来当一个人记的话，合作曲永远命不中她真正喜欢那位。
  static final _splits = RegExp(r'[、,，/＆&]|\s(?:feat|ft)\.?\s', caseSensitive: false);

  static List<String> artistsOf(Song s) {
    final out = <String>[];
    for (final raw in s.singer.split(_splits)) {
      final a = normalizeArtist(raw);
      if (a.isNotEmpty && !out.contains(a)) out.add(a);
    }
    return out;
  }

  static String normalizeArtist(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// 半衰期 45 天：口味变得慢，上周的偏好这周还该作数，但半年前沉迷过的那个人
  /// 不该再占住今天的位置。没有日期的信号（收藏、歌单）按常青算。
  static double _decay(int atMs, DateTime now) {
    if (atMs <= 0) return 1;
    final days = now.difference(DateTime.fromMillisecondsSinceEpoch(atMs)).inDays;
    if (days <= 0) return 1;
    return days > 400 ? 0.06 : pow(0.5, days / 45).toDouble();
  }

  /// 听得很熟：反复播却一次没听完、或者已经听完好几遍 —— 再推到「今日私荐」里
  /// 就是把她听厌的歌端上来，这一列当天就废了。
  static bool _isWorn(int plays, int done, int heard, int totalSec) =>
      (plays >= 6 && done == 0) ||
      done >= 3 ||
      (done >= 1 && totalSec > 0 && heard >= totalSec - 5);

  /// 几天之内听过的算「刚听过」，当天不再上私荐。三天是拿她一天的使用节奏定的：
  /// 早上听过的歌晚上不会想再看到，但隔了个周末再遇见还是新鲜的。
  static const _recentDays = 3;

  /// 私荐一屏里同一位歌手最多占几首。口味只要偏一点，纯按分数排就会让某一位
  /// 霸掉半屏 ——她要的是「像我的歌」，不是「同一个人的歌」。
  static const _perArtist = 3;

  /// 由曲库里的三份列表 + 一份播放计数算出口味。
  ///
  /// 计数用记录类型传，不引 [PlayStat]：那样这一层就要 import 带 path_provider 的
  /// 存储，纯函数就没法在离线测试里单独算了。
  ///
  /// [backfill] 是给「只在计数里出现」的那些歌补的歌手名和时长。最近播放只留 200 条，
  /// 她半年前反复听完过的那个人早被挤出列表了 —— 没有这一份，那些计数就再也算不到
  /// 任何人头上。
  factory Taste.from({
    required List<Song> favorites,
    required List<Song> recent,
    required List<Song> playlistSongs,
    required Map<String, ({int plays, int done, int heard, int at})> stats,
    Map<String, ({String singer, int interval})> backfill = const {},
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final artists = <String, double>{};
    final albums = <String, double>{};
    final display = <String, String>{};
    final worn = <String>{};
    final justHeard = <String>{};
    final fav = {for (final s in favorites) keyOf(s)};
    final inSheets = <String, int>{};
    for (final s in playlistSongs) {
      final k = keyOf(s);
      inSheets[k] = (inSheets[k] ?? 0) + 1;
    }
    // 收藏里的歌不一定出现在最近播放（只收藏没播、或者老数据），反过来也是。
    // 并成一份去重的表，每首歌只算一次，免得同一首既进收藏又播过就被记两遍。
    final songs = <String, Song>{};
    for (final s in [...favorites, ...playlistSongs, ...recent]) {
      songs.putIfAbsent(keyOf(s), () => s);
    }

    /// 把一首歌的信号摊到它的每位署名、每张专辑上。
    void credit(String key, String rawSingers, String? album, double w, int plays, int done,
        int heard, int atMs, int totalSec) {
      if (w <= 0) return;
      if (plays > 0 &&
          atMs > 0 &&
          now.difference(DateTime.fromMillisecondsSinceEpoch(atMs)).inDays < _recentDays) {
        justHeard.add(key);
      }
      final decayed = w * _decay(atMs, now);
      for (final raw in rawSingers.split(_splits)) {
        final a = normalizeArtist(raw);
        if (a.isEmpty) continue;
        artists[a] = ((artists[a] ?? 0) + decayed).clamp(0.0, 24.0);
        display.putIfAbsent(a, () => raw.trim());
      }
      if (album != null && album.isNotEmpty) {
        albums[album] = ((albums[album] ?? 0) + decayed).clamp(0.0, 12.0);
      }
      if (_isWorn(plays, done, heard, totalSec)) worn.add(key);
    }

    /// 计数本身能撑出多少分的喜好。听完是最强的一档，点开过只算零头。
    double fromCounts(int plays, int done, int heard) {
      var w = 0.0;
      if (done > 0) w += 2.0 * (done > 3 ? 3.0 : done.toDouble());
      if (plays > 0) w += 0.4 * (plays > 5 ? 5.0 : plays.toDouble());
      if (heard > 0) w += heard > 180 ? 1.5 : heard / 120;
      return w;
    }

    for (final e in songs.entries) {
      final st = stats[e.key];
      final plays = st?.plays ?? 0;
      final done = st?.done ?? 0;
      final heard = st?.heard ?? 0;
      final atMs = st?.at ?? 0;
      var w = 0.0;
      if (fav.contains(e.key)) w += 5;
      final sheets = inSheets[e.key] ?? 0;
      if (sheets > 0) w += 1.2 * (sheets > 3 ? 3.0 : sheets.toDouble());
      w += fromCounts(plays, done, heard);
      // 收藏和歌单里没有日期的（刚加进去、还没播过）按常青算，见 [_decay]。
      credit(e.key, e.value.singer, e.value.albumName, w, plays, done, heard, atMs,
          e.value.interval ?? 0);
    }
    // 已经被挤出最近播放、又没进收藏的那些：口味只认得这份补回来的名字。
    for (final e in stats.entries) {
      if (songs.containsKey(e.key)) continue;
      final known = backfill[e.key];
      if (known == null) continue;
      credit(e.key, known.singer, null, fromCounts(e.value.plays, e.value.done, e.value.heard),
          e.value.plays, e.value.done, e.value.heard, e.value.at, known.interval);
    }
    if (artists.isEmpty) return empty;
    return Taste(
        artists: artists,
        albums: albums,
        wornOut: worn,
        heardRecently: justHeard,
        display: display);
  }

  /// 挑歌：先去重，再把听厌的、这几天刚听过的从池子里拿掉，剩下的按贴合度从高到低
  /// 取前 count 首，同一位歌手最多占 [_perArtist] 首。
  ///
  /// 听厌的歌只扣分不删除是不够的 —— 它命中的是她最爱那位歌手，扣 6 分照样能排进
  /// 前三，结果就是「怎么又是这首」。但一屏都凑不满时还是得放回来，宁可重复也别空着。
  ///
  /// 同一天分数一模一样（她没再听任何东西的话），换一天则靠 [_jitter] 重排一次，
  /// 于是「今日私荐」每天看起来都在动，但排序本身没被搅乱。
  /// 口味为空（她还没听出任何偏好）时也一样能跑，只是分不出高下、由抖动决定顺序。
  List<Song> rank(List<Song> pool,
      {required int count, DateTime? at, bool Function(Song)? swapReady}) {
    final d = at ?? DateTime.now();
    // 新歌位和榜单是两份名单，同一首歌常常两边都在：不去重就会在同一屏里出现两遍，
    // 而分数一模一样的那些还正好紧挨着排。
    final seen = <String>{};
    final uniq = [for (final s in pool) if (seen.add(keyOf(s))) s];
    final skip = {...wornOut, ...heardRecently};
    final fresh =
        skip.isEmpty ? uniq : [for (final s in uniq) if (!skip.contains(keyOf(s))) s];
    final use = fresh.length >= count ? fresh : uniq;
    if (use.length <= count) return List.of(use);
    final scored = [
      for (final s in use) (song: s, score: scoreOf(s, swapReady: swapReady) + _jitter(s, d))
    ]
      ..sort((a, b) => b.score.compareTo(a.score));
    return _spread([for (final e in scored) e.song], count);
  }

  /// 按分数顺序取 count 首，但一位歌手最多取 [_perArtist] 首；被上限挡住的那些先
  /// 攒着，一屏没填满时再按原顺序补回来 —— 挡重复是锦上添花，凑不满一屏不是。
  List<Song> _spread(List<Song> ordered, int count) {
    final out = <Song>[];
    final held = <Song>[];
    final used = <String, int>{};
    for (final s in ordered) {
      if (out.length >= count) return out;
      final a = _topArtist(s);
      if (a != null && (used[a] ?? 0) >= _perArtist) {
        held.add(s);
        continue;
      }
      if (a != null) used[a] = (used[a] ?? 0) + 1;
      out.add(s);
    }
    for (final s in held) {
      if (out.length >= count) break;
      out.add(s);
    }
    return out;
  }

  /// 一首歌身上最重的那位歌手。合作曲按主咖记账：她的口味本来就由主咖带出来的，
  /// 把 feat. 的那位也算成占位的人，等于替别人挡掉了这首歌。
  /// 口味里还不认识的歌手照样占一个位置 —— 上限要的是「别是同一个人占满一屏」，
  /// 这一位她认不认识跟这件事无关。
  String? _topArtist(Song s) {
    final list = artistsOf(s);
    if (list.isEmpty) return null;
    var best = list.first;
    var w = artists[best] ?? 0;
    for (final a in list) {
      final v = artists[a] ?? 0;
      if (v > w) {
        w = v;
        best = a;
      }
    }
    return best;
  }

  /// 一首歌对口味的贴合度。命中她反复听过的歌手是唯一的主分，其余几项都只用来
  /// 把同分的歌排开一点。
  double scoreOf(Song s, {bool Function(Song)? swapReady}) {
    var score = 0.0;
    for (final a in artistsOf(s)) {
      score += artists[a] ?? 0;
    }
    final album = s.albumName;
    if (album != null && album.isNotEmpty) score += (albums[album] ?? 0) * 0.4;
    if (wornOut.contains(keyOf(s))) score -= 6;
    // 会员墙后面的歌压一档：这台手机上它多半要绕一整条换源链子才出得来声音，
    // 一屏里塞三首这种，她的感受就是「今天怎么又是放不出的」。
    // 已经备好免费版的那些不压 —— 一按就出声，和免费歌没差别，压下去恰好把她
    // 常听的那几位挤出屏幕。换源缓存记在 LibraryStore 里，口味这层不碰存储，
    // 所以由调用方告诉她「这首现在一按就响」。
    if (s.needsVip && !(swapReady?.call(s) ?? false)) score -= 2.5;
    return score;
  }

  /// 她最常听的几位，用来在界面上说清「这批是按什么挑的」。名字按曲库里出现过的那个
  /// 子样还回去，别让「adele」「TAYLOR SWIFT」这种大小写残在句子里。
  List<String> topArtists([int n = 3]) {
    final list = artists.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list.take(n).map((e) => display[e.key] ?? e.key).toList();
  }

  /// 每天给每首歌一个最多 0.04 的固定小偏移。
  ///
  /// 为什么不用洗牌：洗牌会把 4.0 分的歌抬到 4.9 分前面，等于口味白算了一遍。
  /// 0.04 比这里最小的真实信号（一次没听完 +0.4）还低一个数量级，任何一次认真的
  /// 收听都压得住它，但足够让同分的歌每天轮换一次位置。
  static double _jitter(Song s, DateTime at) {
    var h = at.year * 372 + at.month * 31 + at.day;
    for (final c in keyOf(s).runes) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return (h % 1000) / 1000 * 0.04;
  }
}
