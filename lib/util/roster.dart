/// 明星名单：A–Z 加一格「其它」，以及在这份名单上就地筛词、分组、逐格装载的纯逻辑。
///
/// 名单不是本机攒出来的，是从网易云 `/api/artist/list` 一格一格拉回来的（那一头的
/// 窗口规矩写在 `WyCatalog.artistsByLetter`）。这一层只碰数据不碰网络：「一格怎么拉」
/// 是递进来的回调，单测里换一个假的就能把整个装载过程跑完。
library;

import '../models/results.dart';
import 'fuzzy_query.dart';

/// 「其它」那一格：数字、符号、生僻开头的都收在这儿。界面上的标题是「其它」，
/// 递给接口要换成 `0`。
const rosterOther = '#';

/// 名单的格子顺序：26 个字母，「其它」固定排最后。装载、渲染、右侧索引条都按这个顺序走。
const rosterLetters = <String>[
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  rosterOther,
];

/// 一格几位。这是接口给的窗口（`offset + limit` 越过 100 就整页回空），不是「这位歌手一共有多少」，
/// 所以界面上只能写「每个字母前 100 位」，不能写「全量曲库」。
const rosterBucketSize = 100;

/// 界面上的字母 → 接口认的 `initial`：大写字母的字符码，「其它」是 `0`。
String rosterInitialCode(String letter) =>
    letter == rosterOther ? '0' : letter.toUpperCase().codeUnitAt(0).toString();

/// 格子标题。
String rosterGroupLabel(String letter) => letter == rosterOther ? '其它' : letter;

/// 一组：一格字母加这一格里的人。
class RosterGroup {
  final String letter;
  final List<ArtistInfo> artists;
  RosterGroup(this.letter, this.artists);

  String get label => rosterGroupLabel(letter);
  int get count => artists.length;
}

/// 按格子顺序排出屏上那几组。[keyword] 非空时就是就地筛过的那批，
/// 空掉的格子不再占一行标题。格子里的顺序照接口给的热度排，不按名字重排：
/// 中文名按码位排出来是一团乱的（「郑」的代码位在「张」前面），接口那个顺序至少是有意义的。
List<RosterGroup> rosterGroups(Map<String, List<ArtistInfo>> buckets, {String keyword = ''}) {
  final kw = _tight(normalizeKeyword(keyword));
  final out = <RosterGroup>[];
  for (final letter in rosterLetters) {
    final src = buckets[letter];
    if (src == null || src.isEmpty) continue;
    final hit = kw.isEmpty ? src : src.where((a) => rosterMatch(a, kw)).toList();
    if (hit.isNotEmpty) out.add(RosterGroup(letter, hit));
  }
  return out;
}

/// 名字或别名里含着这个词就算中。[kw] 要先小写、先过 [normalizeKeyword]、再去掉空白
/// （就是 [_tight] 那一步）—— 别名两头都可能有空格，逐格比对时空格不该算差异。
/// 别名装着外语名和中文名（「Eason Chan」「陈奕迅」两头都在），打哪头都能命中。
bool rosterMatch(ArtistInfo artist, String kw) {
  if (kw.isEmpty) return true;
  return _tight(artist.name).contains(kw) || _tight(artist.alias).contains(kw);
}

/// 小写 + 抹掉所有空白：「林 俊杰」「eason chan」这种带空格的写法，
/// 在她手里和本机名单上是同一个词。
String _tight(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

/// 屏上现在一共有几位。
int rosterCount(List<RosterGroup> groups) => groups.fold(0, (s, g) => s + g.count);

/// 还缺哪几格（按 [rosterLetters] 排）。界面上那一行「N 格没拉回来」和索引条上摆不摆
/// 这个字母，都从这儿来。
List<String> missingBuckets(Map<String, List<ArtistInfo>> buckets) =>
    rosterLetters.where((l) => !(buckets[l]?.isNotEmpty ?? false)).toList();

/// 一次装载的结果：拉回来的格子 + 没答话的格子。
class RosterLoad {
  final Map<String, List<ArtistInfo>> buckets;

  /// 按 [rosterLetters] 排好的缺口的格。
  final List<String> failed;
  RosterLoad(this.buckets, this.failed);

  int get artistCount => buckets.values.fold(0, (s, v) => s + v.length);
}

/// 一格一格把名单拉回来。[fetch] 负责拉一格（砸了就抛）。
///
/// 三格三格地拉。2026-10-29 拿真接口连打两遍量过（`research/discover/probe_roster6.out`）：
/// 单格 70–140ms、27 格整批 794ms / 910ms。这一档不是为了快，是为了别一口气向同一个接口
/// 连发 27 次 —— 那才是把自己往网易云那条按频率算的限流上撞。逐格上屏（[onBucket]）同理也不是
/// 为了安抚等待（不到一秒就完了），是头一格 81ms 一到手她就能点。
/// 每格就地重试一次，两次都砸才记进缺口 ——
/// 拉回来的格子照常上屏，别让一格砸了就把整份名单扔掉。
///
/// 回空也算没答话：实测每一格都回满 100 位，空着回来的是接口在推卸，不是这一格真没人。
Future<RosterLoad> loadRoster(
  Future<List<ArtistInfo>> Function(String letter) fetch, {
  void Function(String letter, List<ArtistInfo> artists)? onBucket,
  int concurrency = 3,
}) async {
  final buckets = <String, List<ArtistInfo>>{};
  final failed = <String>[];
  final queue = rosterLetters.toList();
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final letter = queue.removeAt(0);
      List<ArtistInfo>? got;
      for (var attempt = 0; attempt < 2 && got == null; attempt++) {
        try {
          final artists = await fetch(letter);
          if (artists.isNotEmpty) got = artists;
        } catch (_) {
          got = null;
        }
      }
      final artists = got;
      if (artists == null) {
        failed.add(letter);
        onBucket?.call(letter, const []);
      } else {
        buckets[letter] = artists;
        onBucket?.call(letter, artists);
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  failed.sort((a, b) => rosterLetters.indexOf(a).compareTo(rosterLetters.indexOf(b)));
  return RosterLoad(buckets, failed);
}

/// 还在逐格拉时那一行。
String rosterProgressNote({required int done, required int total, required int loaded}) =>
    '名单加载中 $done/$total · 已上屏 $loaded 位';

/// 有格子没答话时那一行：缺哪几格、屏上有多少位，都得说给她听。
String rosterPartialNote({required List<String> failed, required int loaded}) {
  final names = failed.map(rosterGroupLabel).join('、');
  return '$names 共 ${failed.length} 格没拉回来 · 屏上是 $loaded 位';
}
