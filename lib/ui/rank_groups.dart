import '../models/results.dart';

/// 发现页的一次 `toplist` 调用会拿回 60 多个榜，平铺成宫格既翻不完也看不出轻重。
/// 这里按榜单名归成四组，接口以后加新榜也不会漏掉——认不出的一律进「其他榜单」。
class RankGroup {
  final String title;
  final List<RankInfo> ranks;
  const RankGroup(this.title, this.ranks);

  bool get isEmpty => ranks.isEmpty;
}

/// 官方四大榜。必须全名匹配：带「热歌榜」「新歌榜」字样的衍生榜（网络热歌榜、
/// 黑胶VIP新歌榜…）也有一堆，用关键词会把它们错抬进主榜。
const _mainNames = {'飙升榜', '新歌榜', '原创榜', '热歌榜'};

/// 风格榜：词表都带「榜」字，避开「喜力星电音派对潮音榜」这类品牌活动榜。
const _styleKeys = [
  '古典榜', '电音榜', '说唱榜', '摇滚榜', '民谣榜', '国风榜',
  'ACG', 'DJ榜', 'R&B榜', '欧美', 'KTV', 'BEAT排行榜',
];

/// 海外/语种榜。
const _overseasKeys = [
  'Billboard', 'UK排行', 'Oricon', 'Beatport', 'NRJ', '法国',
  '俄罗斯', 'Melon', '韩国', 'iTunes', 'Spotify',
  '韩语榜', '日语榜', '俄语榜', '越南语榜', '泰语榜',
];

List<RankGroup> groupRanks(List<RankInfo> ranks) {
  final main = <RankInfo>[], style = <RankInfo>[], overseas = <RankInfo>[], other = <RankInfo>[];
  for (final r in ranks) {
    final n = r.name.trim();
    if (_mainNames.contains(n)) {
      main.add(r);
    } else if (_overseasKeys.any(n.contains)) {
      overseas.add(r);
    } else if (_styleKeys.any(n.contains)) {
      style.add(r);
    } else {
      other.add(r);
    }
  }
  final groups = [
    RankGroup('官方主榜', main),
    RankGroup('风格榜', style),
    RankGroup('海外榜', overseas),
    RankGroup('其他榜单', other),
  ];
  return groups.where((g) => !g.isEmpty).toList();
}

/// 首页只放最能代表「今天大家在听什么」的榜，其余进发现页看。
List<RankInfo> homeRanks(List<RankInfo> ranks) {
  for (final g in groupRanks(ranks)) {
    if (g.title == '官方主榜') return g.ranks;
  }
  return ranks.take(6).toList();
}
