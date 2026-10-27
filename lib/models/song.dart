class SongQuality {
  final String type;
  final String? size;
  SongQuality(this.type, [this.size]);
  Map<String, dynamic> toJson() => {'type': type, 'size': size};
}

class Song {
  String songmid;
  String source;
  String? types;
  String? id;
  String name;
  String singer;
  String? albumId;
  String? albumName;
  String? pic;
  int? interval;
  String? qualitys; // comma joined

  /// 网易云的版权标记。实测：fee=1 的歌端内直连 128k/320k/flac 三档全部拿不到链接，
  /// fee=0 和 8 则都能出——所以这一个数字就够判断「这首十有八九要换版本」。
  /// QQ 用 payplay、酷狗用搜索里的 `Privilege>=10` 各自折算成同一个 1；
  /// 酷我等其他曲库没有可靠的标记，留 0 表示未知/免费。
  final int fee;
  Map<String, SongQuality> _types;

  Song({
    this.songmid = '',
    this.source = '',
    this.types,
    this.id,
    this.name = '',
    this.singer = '',
    this.albumId,
    this.albumName,
    this.pic,
    this.interval,
    this.qualitys,
    this.fee = 0,
    Map<String, SongQuality>? typeMap,
  }) : _types = typeMap ?? {};

  Map<String, SongQuality> get typeMap => _types;

  /// 这首在网易云端内放不出来（会员/付费墙）。
  bool get needsVip => fee == 1 && source == 'wy';

  /// 合唱串里的第一个名字。点歌手名去搜索时塞整串（「陶喆、张韶涵」）只会什么都
  /// 搜不到，而各家的连接符还不一样：网易云用「、」，QQ 用「/」，酷我用「,」。
  String get leadArtist {
    for (final part in singer.split(_artistSplit)) {
      final name = part.trim();
      if (name.isNotEmpty) return name;
    }
    return singer.trim();
  }

  static final RegExp _artistSplit = RegExp(r'[、,/／]');

  /// 换源时这条候选本身就被付费墙挡着。网易云 fee=1 要会员，腾讯 payplay=1 同样要
  /// 会员（实测匿名取链回 result:104003）；酷狗用搜索里的 `Privilege>=10` 判（见
  /// KgNative.search，匿名直链对这种歌一律回 `status:2`）。酷我的付费标记不可靠，
  /// 交给取链去判断。
  bool get twinBlocked => fee == 1 && (source == 'wy' || source == 'tx' || source == 'kg');

  /// 把明显是分支版本的排到最后，其余顺序原样保留（榜单名次、搜索相关度）。
  ///
  /// 自检/检测拿哪首都算「这个平台通不通」，但界面上写「拿《晴天（DJ降调0.9x版）》
  /// 试出来的档位」就没人信这是同一首歌了。网易云的 cloudsearch 匿名结果里翻唱、
  /// 深情版、AI 版能占掉大半，所以这一步现在 wy 和 tx 两边都要走。
  /// 带括号的基本不是原版，这一刀够便宜也不误伤：真原版偶尔带括号时它只是排到最后，
  /// 仍然会被用上。
  static List<Song> preferOriginal(Iterable<Song> songs) {
    final tagged = songs.where((s) => _bracket.hasMatch(s.name)).toList();
    return [...songs.where((s) => !_bracket.hasMatch(s.name)), ...tagged];
  }

  static final RegExp _bracket = RegExp(r'[（(【\[]');

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        songmid: j['songmid'] ?? j['hash'] ?? j['mid'] ?? '',
        source: j['source'] ?? '',
        id: j['id']?.toString(),
        name: j['name'] ?? '',
        singer: j['singer'] ?? '',
        albumId: j['albumId']?.toString(),
        albumName: j['albumName'],
        pic: j['pic'],
        interval: j['interval'] is num ? (j['interval'] as num).toInt() : null,
        fee: j['fee'] is num ? (j['fee'] as num).toInt() : 0,
        typeMap: (j['types'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), SongQuality(k.toString(), v?['size']?.toString())),
            ) ??
            {},
      );

  Song mergeRaw(Map<String, dynamic> raw) {
    // merge a search-result song object (lx format) into this instance
    id = raw['id']?.toString() ?? id;
    name = raw['name'] ?? name;
    singer = raw['singer'] ?? singer;
    albumName = raw['albumName'] ?? albumName;
    albumId = raw['albumId']?.toString() ?? albumId;
    pic = raw['pic'] ?? pic;
    if (raw['duration'] is num) interval = (raw['duration'] as num).toInt();
    if (raw['interval'] is num) interval = (raw['interval'] as num).toInt();
    final t = raw['types'];
    if (t is List) {
      for (final q in t) {
        if (q is Map) {
          final type = q['type']?.toString();
          if (type != null) _types[type] = SongQuality(type, q['size']?.toString());
        }
      }
    } else if (t is Map) {
      t.forEach((k, v) => _types[k.toString()] = SongQuality(k.toString(), v?.toString()));
    }
    final sq = raw['source'];
    if (sq is String) source = sq;
    final mid = raw['songmid'] ?? raw['hash'] ?? raw['mid'];
    if (mid != null) songmid = mid.toString();
    return this;
  }

  Map<String, dynamic> toJson() => {
        'songmid': songmid,
        'source': source,
        'id': id,
        'name': name,
        'singer': singer,
        'albumId': albumId,
        'albumName': albumName,
        'pic': pic,
        'interval': interval,
        'fee': fee,
        'types': _types.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// The `musicInfo` object the lx-music protocol hands to user scripts for
  /// the `musicUrl` action. Scripts read different id fields per source
  /// (`hash ?? songmid`, `songmid || id || mid`), so we mirror the single
  /// identifier we captured across all of them. For kw that identifier is the
  /// numeric rid, which lx-music-mobile also treats as the hash.
  Map<String, dynamic> toMusicInfo() => {
        'name': name,
        'singer': singer,
        'text': '$name $singer'.trim(),
        'albumName': albumName,
        'albumId': albumId,
        'id': id ?? songmid,
        'songmid': songmid,
        'hash': songmid,
        'mid': songmid,
        'sid': songmid,
        'interval': interval,
        'duration': interval,
        'source': source,
        'types': _types.map((k, v) => MapEntry(k, v.size ?? '')),
      };

  String get qualityLabels => _types.keys.join(',');

  static List<Song> listFromJson(dynamic arr) =>
      (arr as List?)?.map((e) => Song.fromJson(Map<String, dynamic>.from(e))).toList() ?? [];
}

/// 这一首在这台手机上**实际**能听到的档位。
///
/// 设置里那一档是「想要」，不是「拿得到」：匿名出整首的那几条各有上限
/// （B 站 192k，QQ、酷狗只有 128k），会员墙后面靠它们兜底的歌永远到不了无损。以前播放页
/// 和下载弹窗都直接写设置值，于是「无损 flac · 免费版」挂在耳朵是 192k 那儿 ——
/// 换源本来就看不见摸不着，标注再骗人，她更不会信这功能是真是的。
/// 预取也把这一档写进文件名：按设置值存的话，B 站那首歌在无损和 320k 两个键下
/// 各存一份同样的字节，改一次设置就重下一遍。
String heardQuality(String wanted, String source) {
  final cap = switch (source) {
    'bl' => '192k',
    'tx' || 'kg' => '128k',
    _ => null,
  };
  if (cap == null) return wanted;
  const order = ['128k', '192k', '320k', 'flac'];
  return order.indexOf(cap) < order.indexOf(wanted) ? cap : wanted;
}

/// 档位码给人看的名字。以前只有设置页有一张对照表，别处（播放页那行「现在听到的是
/// 哪一档」、下载确认、音源自检）就直接把「flac」念出来——她看见的是代码不是档位。
/// 未知代码原样带出来：B 站那档是 192k，写成「高清 320k」就是骗人。
String qualityLabel(String q) => switch (q) {
      '128k' => '标准 128k',
      'flac' => '无损 flac',
      _ => '高清 $q',
    };

/// 来源码给人看的名字。这是**唯一**一份对照表：
/// 界面（`sourceLabel`）、取链失败台账（`BuiltinLibrary._twinLabel`）、撞墙那句
/// （`_wallHome`）都从这里念，接一个新平台只改这一处。
/// 各写一份的后果已经栽过：日志前缀漏出「换源 bl：」这种半成品，
/// 或者新平台的名字永远读不出来。
String sourceName(String source) => switch (source) {
      'wy' => '网易云',
      'kw' => '酷我',
      'tx' => 'QQ',
      'bl' => 'B 站',
      'kg' => '酷狗',
      _ => source,
    };
