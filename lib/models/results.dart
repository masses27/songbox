
import '../models/song.dart';

class SearchResult {
  final int total;
  final int allPage;
  final List<Song> list;
  SearchResult(this.total, this.allPage, this.list);

  static SearchResult fromApi(Map<String, dynamic> body, String source) {
    final songs = (body['songs'] ?? body['list'] ?? []) as List;
    final list = songs.map((raw) {
      final s = Song(source: source);
      try {
        return s.mergeRaw(raw as Map<String, dynamic>);
      } catch (_) {
        return s;
      }
    }).toList();
    return SearchResult(
      body['total'] as int? ?? list.length,
      body['allPage'] as int? ?? 1,
      list,
    );
  }
}

/// 搜索联想条目：text 填进搜索框，hint 是右侧灰字提示。
class SuggestItem {
  final String text;
  final String hint;
  const SuggestItem(this.text, this.hint);
}

class LyricResult {
  final String lyric;
  final String? tlyric;
  final String? rlyric;
  final String? lxlyric;
  LyricResult({required this.lyric, this.tlyric, this.rlyric, this.lxlyric});

  factory LyricResult.fromJson(Map<String, dynamic> j) => LyricResult(
        lyric: j['lyric'] as String? ?? '',
        tlyric: j['tlyric'] as String?,
        rlyric: j['rlyric'] as String?,
        lxlyric: j['lxlyric'] as String?,
      );
}

class RankInfo {
  final String source;
  final String id;
  final String name;

  /// 榜单封面。网易云的 api/toplist 每条都带 coverImgUrl，酷我是编译期常量表没有，
  /// 所以可空 —— 没图时界面回落到图标占位。
  final String? img;

  /// 一句话说明（「每天更新 100 首」这类），卡片副标题用。
  final String? desc;

  const RankInfo(this.source, this.id, this.name, {this.img, this.desc});

  factory RankInfo.fromJson(Map<String, dynamic> j) {
    final img = (j['img'] ?? j['coverImgUrl'] ?? j['coverImageUrl'] ?? j['picUrl'])?.toString();
    return RankInfo(
      j['source'] ?? '',
      '${j['id'] ?? j['boardId'] ?? ''}',
      j['name'] ?? '',
      img: (img == null || img.isEmpty) ? null : img,
      desc: (j['desc'] ?? j['description'])?.toString().trim(),
    );
  }
}

class SheetInfo {
  final String source;
  final String id;
  final String name;
  final String? img;
  final String? desc;

  /// 播放量，0 表示接口没给（榜单和第三方源经常缺这个字段）。
  final int playCount;
  SheetInfo(this.source, this.id, this.name, this.img, this.desc, {this.playCount = 0});

  factory SheetInfo.fromJson(Map<String, dynamic> j) => SheetInfo(
        j['source'] ?? '',
        '${j['id'] ?? j['sheetId'] ?? ''}',
        j['name'] ?? j['title'] ?? '',
        j['img'] ?? j['coverImgUrl'] ?? j['image'],
        j['desc'] ?? j['description'],
        playCount: num.tryParse('${j['playCount'] ?? j['realPlayCount'] ?? 0}')?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'source': source,
        'id': id,
        'name': name,
        'img': img,
        'desc': desc,
        'playCount': playCount,
      };

  /// 收藏去重用的键：同一首歌在两个曲库里 id 可能撞号。
  String get key => '$source:$id';
}

/// A singer, as returned by search and the artist endpoints.
class ArtistInfo {
  final String source;
  final String id;
  final String name;
  final String? pic;
  final String? banner;

  /// Foreign name / 中文名, e.g. Eason Chan.
  final String alias;
  final int musicSize;
  final int albumSize;
  final String desc;

  ArtistInfo({
    required this.source,
    required this.id,
    required this.name,
    this.pic,
    this.banner,
    this.alias = '',
    this.musicSize = 0,
    this.albumSize = 0,
    this.desc = '',
  });

  static ArtistInfo? fromNetEase(Map? j, {String source = 'wy'}) {
    if (j == null || j['id'] == null) return null;
    final alias = (j['alias'] ?? j['alia'] ?? j['trans']) as List?;
    final pic = j['picUrl']?.toString();
    final banner = j['img1v1Url']?.toString();
    return ArtistInfo(
      source: source,
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      pic: (pic == null || pic.isEmpty) ? null : pic,
      banner: (banner == null || banner.isEmpty) ? null : banner,
      alias: alias?.map((e) => '$e').where((e) => e.isNotEmpty).join(' / ') ?? '',
      musicSize: (j['musicSize'] as num?)?.toInt() ?? 0,
      albumSize: (j['albumSize'] as num?)?.toInt() ?? 0,
      desc: '${j['briefDesc'] ?? j['mvBriefDesc'] ?? ''}'.trim(),
    );
  }
}

/// An album (专辑 / Single), from album search, artist detail or album detail.
class AlbumInfo {
  final String source;
  final String id;
  final String name;
  final String? pic;
  final String artist;
  final String artistId;
  final int size;
  final int publishTimeMs;
  final String type;
  final String desc;

  AlbumInfo({
    required this.source,
    required this.id,
    required this.name,
    this.pic,
    this.artist = '',
    this.artistId = '',
    this.size = 0,
    this.publishTimeMs = 0,
    this.type = '',
    this.desc = '',
  });

  /// NetEase spells the artist in three different places depending on which
  /// endpoint produced the object.
  ///
  /// cloudsearch 那条尤其要绕：它的 `artist` 是个 `{name:'', id:0}` 的空壳，
  /// 真名真号在 `artists[0]` 里。`??` 兜不住空串，所以逐个判非空再往下走。
  static AlbumInfo? fromNetEase(Map? j, {String source = 'wy'}) {
    if (j == null || j['id'] == null) return null;
    final pic = (j['picUrl'] ?? j['blurPicUrl'])?.toString();
    final artist = j['artist'] is Map ? j['artist'] as Map : null;
    final first = (j['artists'] is List && (j['artists'] as List).isNotEmpty)
        ? j['artists'].first as Map?
        : null;
    String? text(Object? v) => (v == null || '$v'.isEmpty) ? null : '$v';
    String? idOf(Object? v) {
      final s = text(v);
      return s == '0' ? null : s;
    }
    return AlbumInfo(
      source: source,
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      pic: (pic == null || pic.isEmpty) ? null : pic,
      artist: text(artist?['name']) ?? text(first?['name']) ?? '',
      artistId: idOf(artist?['id']) ?? idOf(first?['id']) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      publishTimeMs: (j['publishTime'] as num?)?.toInt() ?? 0,
      type: '${j['type'] ?? ''}',
      desc: '${j['briefDesc'] ?? j['description'] ?? ''}'.trim(),
    );
  }

  String get publishYear {
    if (publishTimeMs <= 0) return '';
    return DateTime.fromMillisecondsSinceEpoch(publishTimeMs).toIso8601String().substring(0, 4);
  }
}

