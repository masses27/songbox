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

  /// 归一化名 -> 她曲库里出现过的那个子样（`Adele` 而不是 `adele`）。只用来把
  /// 「按谁挑的」这句话写在界面上：匹配要忽略大小写，展示不能。
  final Map<String, String> display;

  const Taste(
      {required this.artists,
      required this.albums,
      required this.wornOut,
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

  /// 由曲库里的三份列表 + 一份播放计数算出口味。
  ///
  /// 计数用记录类型传，不引 [PlayStat]：那样这一层就要 import 带 path_provider 的
  /// 存储，纯函数就没法在离线测试里单独算了。
  factory Taste.from({
    required List<Song> favorites,
    required List<Song> recent,
    required List<Song> playlistSongs,
    required Map<String, ({int plays, int done, int heard, int at})> stats,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final artists = <String, double>{};
    final albums = <String, double>{};
    final display = <String, String>{};
    final worn = <String>{};
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
      // 听完是这里最强的一档信号：点开就算数会把「手滑点开又收回」记成喜欢。
      if (done > 0) w += 2.0 * (done > 3 ? 3.0 : done.toDouble());
      if (plays > 0) w += 0.4 * (plays > 5 ? 5.0 : plays.toDouble());
      if (heard > 0) w += heard > 180 ? 1.5 : heard / 120;
      if (w <= 0) continue;
      w *= _decay(atMs, now);
      for (final raw in e.value.singer.split(_splits)) {
        final a = normalizeArtist(raw);
        if (a.isEmpty) continue;
        artists[a] = ((artists[a] ?? 0) + w).clamp(0.0, 24.0);
        display.putIfAbsent(a, () => raw.trim());
      }
      final album = e.value.albumName;
      if (album != null && album.isNotEmpty) {
        albums[album] = ((albums[album] ?? 0) + w).clamp(0.0, 12.0);
      }
      if (_isWorn(plays, done, heard, e.value.interval ?? 0)) worn.add(e.key);
    }
    if (artists.isEmpty) return empty;
    return Taste(artists: artists, albums: albums, wornOut: worn, display: display);
  }

  /// 挑歌：先把听厌的直接从池子里拿掉，剩下的按贴合度从高到低取前 count 首。
  ///
  /// 听厌的歌只扣分不删除是不够的 —— 它命中的是她最爱那位歌手，扣 6 分照样能排进
  /// 前三，结果就是「怎么又是这首」。但一屏都凑不满时还是得放回来，宁可重复也别空着。
  ///
  /// 同一天分数一模一样（她没再听任何东西的话），换一天则靠 [_jitter] 重排一次，
  /// 于是「今日私荐」每天看起来都在动，但排序本身没被搅乱。
  /// 口味为空（她还没听出任何偏好）时也一样能跑，只是分不出高下、由抖动决定顺序。
  List<Song> rank(List<Song> pool, {required int count, DateTime? at}) {
    final d = at ?? DateTime.now();
    final fresh = wornOut.isEmpty
        ? pool
        : [for (final s in pool) if (!wornOut.contains(keyOf(s))) s];
    final use = fresh.length >= count ? fresh : pool;
    if (use.length <= count) return List.of(use);
    final scored = [for (final s in use) (song: s, score: scoreOf(s) + _jitter(s, d))]
      ..sort((a, b) => b.score.compareTo(a.score));
    return scored.take(count).map((e) => e.song).toList();
  }

  /// 一首歌对口味的贴合度。命中她反复听过的歌手是唯一的主分，其余几项都只用来
  /// 把同分的歌排开一点。
  double scoreOf(Song s) {
    var score = 0.0;
    for (final a in artistsOf(s)) {
      score += artists[a] ?? 0;
    }
    final album = s.albumName;
    if (album != null && album.isNotEmpty) score += (albums[album] ?? 0) * 0.4;
    if (wornOut.contains(keyOf(s))) score -= 6;
    // 会员墙后面的歌压一档：这台手机上它多半要绕一整条换源链子才出得来声音，
    // 一屏里塞三首这种，她的感受就是「今天怎么又是放不出的」。
    if (s.needsVip) score -= 2.5;
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
