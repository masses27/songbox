import '../models/results.dart';
import '../models/song.dart';
import 'wy_native.dart';
import 'wy_search.dart';

/// 发现页分类面板上的一组：先印 [title]，下面排 [names]。
class SheetCategoryGroup {
  final String title;
  final List<String> names;
  const SheetCategoryGroup(this.title, this.names);
}

/// NetEase recommendation / playlist catalog. Uses the same on-device weapi
/// signing as playback, so no bridge service is involved.
class WyCatalog {
  /// 分类词表：官方那棵树（`/api/playlist/catalogue` 的 70 个词），逐词验过才写下。
  ///
  /// 为什么必须逐个打接口：未知分类**不是错误**——网易云不报错，直接回一张兜底歌单
  /// （2026-10-29 实测首条恒为 `6671216522 捡钱的Penny祢的歌单`、`total=500`）。
  /// 所以点一个死词，界面看到的是「拉到了十几张歌单」，内容却跟这个分类毫无关系，
  /// 她只能一张张点开才发现不对。判据就是「首条是不是那张兜底」，每次测都先立两个瞎写的词当对照。
  /// 这一轮的账：上一版装机的那份是 57 个词，先照树补到 85 个候选逐个打，
  /// 其中 20 个是死词、全部删掉（小语种、法语、德语、意大利语、西班牙语、
  /// 俄语、泰语、R&B、唱作、睡眠、开车、深夜、聚会、动漫、励志、网络热歌、男声、女声、
  /// 纯音乐、儿歌——前三批是 probe11，其余是 probe12 带 700ms 间隔复核的），
  /// 再补上树上剩下验过真有货的 5 个（ACG、网络歌曲、经典、R&B/Soul、驾车），
  /// 净数 57→70，正好就是那棵树。
  /// 剩下的词全部出自接口自己给的那棵树，所以它以后加新榜、新分类，照着这棵树抄就行。
  static const categoryGroups = [
    SheetCategoryGroup('语种', [
      '华语', '欧美', '日语', '韩语', '粤语',
    ]),
    SheetCategoryGroup('风格', [
      '流行', '摇滚', '民谣', '电子', '舞曲', '说唱', '轻音乐', '爵士', '乡村',
      'R&B/Soul', '古典', '民族', '英伦', '金属', '朋克', '蓝调', '雷鬼', '世界音乐',
      '拉丁', 'New Age', '古风', '后摇', 'Bossa Nova',
    ]),
    SheetCategoryGroup('场景', [
      '清晨', '夜晚', '学习', '工作', '午休', '下午茶', '地铁', '驾车',
      '运动', '旅行', '散步', '酒吧',
    ]),
    SheetCategoryGroup('情感', [
      '怀旧', '清新', '浪漫', '伤感', '治愈', '放松', '孤独', '感动', '兴奋', '快乐', '安静', '思念',
    ]),
    SheetCategoryGroup('主题', [
      '综艺', '影视原声', 'ACG', '儿童', '校园', '游戏', '网络歌曲', '经典', '翻唱',
      'KTV', '吉他', '钢琴', '器乐', '榜单', '70后', '80后', '90后', '00后',
    ]),
  ];

  /// 横向那一排常用的：其余收进「全部分类」里，点一下就收起，不常驻占地方。
  /// 「推荐」不是网易云的分类，走的是个性化接口，只有它能「换一批」到新的一页。
  /// 这里每一个词都得是 [categoryGroups] 里的那个写法——`R&B` 是死词，
  /// 界面上看着只是少个斜杠，点进去拿回来的却是兜底那一批。
  static const quickCategories = [
    '推荐', '华语', '欧美', '日语', '韩语', '古风',
    '说唱', '电子', '流行', 'R&B/Soul', '轻音乐', '影视原声',
  ];

  /// 推荐歌单 — personalized playlist cards. [offset] is what 「换一批」 moves by.
  static Future<List<SheetInfo>> recommendedSheets({int limit = 10, int offset = 0}) async {
    final body = await WyNative.weapi({
      'limit': limit,
      'offset': offset,
      'total': true,
      'n': 1000,
      'type': 0,
    }, '/weapi/personalized/playlist');
    return _sheets(body['result']);
  }

  /// 推荐新音乐 — songs from the personalized new-song feed. This endpoint
  /// ignores `offset` (verified: offset 0/10/20 return the same ids), so there
  /// is no 「换一批」 here — only the playlist feed paginates.
  static Future<List<Song>> recommendedSongs({int limit = 20}) async {
    final body = await WyNative.weapi({
      'limit': limit,
      'offset': 0,
      'total': true,
      'type': 1,
    }, '/weapi/personalized/newsong');
    final result = (body['result'] as List?) ?? const [];
    return result
        .whereType<Map>()
        .map((e) => WySearch.parseSong(e['song'] ?? e))
        .whereType<Song>()
        .toList();
  }

  /// 热门歌单 for a category tab. 这一条真的认 offset：2026-10-28 拿「华语」连打
  /// 0/12/24 三页，12 首一组基本不重样（榜首那种大热单偶尔在两页里都挂着），
  /// 所以界面上每一类都能「换一批」，不只是「推荐」那一格。
  ///
  /// `order` 只发 `hot`，界面上不摆排序开关。2026-10-29 拿华语/摇滚各打过一轮：
  /// `collect` 换出来的确实是另一批（同一个 total 下首条完全不同），可它并不是按收藏数排的
  /// ——华语/collect 头一条收藏 738、第六条 13 万，华语/hot 也不按播放数排（头一条 85 万、
  /// 第五条 1530 万）。匿名答的就是这么一团带推荐噪声的东西，任何「最热」「收藏最多」
  /// 这样的字都是骗她；`new` 更直接回空（total=0）。所以只留「换一批」这一颗。
  static Future<List<SheetInfo>> hotSheets(String category,
      {int page = 1, int limit = 30}) async {
    final body = await WyNative.getJson('/api/playlist/list', query: {
      'cat': category,
      'order': 'hot',
      'limit': '$limit',
      'offset': '${(page - 1) * limit}',
    });
    return _sheets(body['playlists']);
  }

  /// 新碟上架的地区胶囊：键是接口认的那个词，值是界面上的字。
  /// 2026-10-29 每档取 20 张、拿 id 求交集量过：`EA`/`JP`/`KR`/`OTHER` 与「全部」分别只
  /// 重样 1/1/0/0 张，是真换了四批碟；写错的词（`EU`、`A`）网易云不报错，交的正是
  /// 「全部」那 20 张（20/20 全重），所以只能照这几个词用。
  /// 「华语」是唯一一颗挨着「全部」的：20 张里 18 张相同 —— 网易云这条接口那份默认流
  /// 本来就八成是华语碟。它换出来的东西确实和「全部」不一样（同档连打两次是 20/20 全重，
  /// 所以那 2 张的差不是接口抖动），只是别指望点下去换一屏。
  static const albumAreas = {
    'ALL': '全部',
    'ZH': '华语',
    'EA': '欧美',
    'JP': '日语',
    'KR': '韩语',
    'OTHER': '其他',
  };

  /// 新碟上架。`total` 恒报 500，`offset` 真的在换碟（2026-10-29 连打 0/12/24 三批、
  /// 每批 12 张，相邻两批一张都不重），所以这一格也能「换一批」。
  /// 每张都带着 `artist.id`，点进去的专辑页能开（拿其中三张的 id 走过 [album]，都回得到曲目）。
  static Future<List<AlbumInfo>> newAlbums(
      {String area = 'ALL', int page = 1, int limit = 30}) async {
    final body = await WyNative.getJson('/api/album/new', query: {
      'area': area,
      'limit': '$limit',
      'offset': '${(page - 1) * limit}',
    });
    return _albums(body['albums']);
  }

  /// 热门歌手。`offset` 认（2026-10-29 连打 0/12/24 三批，每批 12 位，相邻两批一位都不重），
  /// 每条带 `picUrl`、`musicSize`、`albumSize` —— 正是 [ArtistInfo.fromNetEase] 要的那几项。
  /// 只有地区词是摆设：加 `area`/`cat`/`type` 一律回 400，所以这一格不给筛。
  static Future<List<ArtistInfo>> topArtists({int page = 1, int limit = 30}) async {
    final body = await WyNative.getJson('/api/artist/top',
        query: {'offset': '${(page - 1) * limit}', 'limit': '$limit'});
    final raw = (body['artists'] is List) ? body['artists'] as List : const [];
    return raw
        .whereType<Map>()
        .map((e) => ArtistInfo.fromNetEase(e))
        .whereType<ArtistInfo>()
        .toList();
  }

  /// 新歌速递：一次 100 首，不走个性化。
  ///
  /// 和 [recommendedSongs] 的区别就是这一百首是「全网的新歌」而不是「给你的新音乐」，
  /// 而且它能换：接口无视 `area`（2026-10-29 拿 7/96/8/16/0/ZH 各打一次，与 `ALL` 那批
  /// 的交集全是 100/100），`offset` 同样是摆设（offset=12 回来还是那 100 首），
  /// 所以「换一批」是在这一百首里切窗口，不再发第二次请求 —— 一屏 12 首，头八屏是满的、
  /// 第九屏只剩 4 首，再点一次才绕回第一批。
  /// 顺序照接口给的接，界面不说它按什么排：响应里唯一带 time 的字段是 `hearTime`，
  /// 100 条全是 0，没有任何可比的发行时间。
  static Future<List<Song>> freshSongs() async {
    final body = await WyNative.weapi({
      'total': 'true',
      'area': 'ALL',
    }, '/weapi/v1/discovery/new/songs');
    return _songs(body['data']);
  }

  /// 歌手主页 — profile plus the hot songs NetEase ranks for that singer.
  static Future<({ArtistInfo artist, List<Song> songs})> artist(String id) async {
    final body = await WyNative.getJson('/api/artist/$id');
    final artist = ArtistInfo.fromNetEase(body['artist'] as Map?);
    if (artist == null) throw Exception('取不到这位歌手的信息');
    final songs = _songs(body['hotSongs']);
    return (artist: artist, songs: songs);
  }

  /// 歌手作品分页 — the artist page used to stop at NetEase's ~50 hot songs.
  static Future<SearchResult> artistSongs(String id, {int page = 1, int pageSize = 30}) async {
    final body = await WyNative.weapi({
      'id': id,
      'offset': (page - 1) * pageSize,
      'limit': pageSize,
      'order': 'hot',
      'total': true,
    }, '/weapi/v1/artist/songs');
    final songs = _songs(body['songs']);
    final total = (body['total'] as num?)?.toInt() ?? songs.length;
    if (songs.isEmpty && total > 0) return SearchResult(total, (total / pageSize).ceil(), const []);
    return SearchResult(total, (total / pageSize).ceil(), songs);
  }

  static Future<List<AlbumInfo>> artistAlbums(String id, {int page = 1, int limit = 30}) async {
    final body = await WyNative.getJson('/api/artist/albums/$id',
        query: {'offset': '${(page - 1) * limit}', 'total': 'true', 'limit': '$limit'});
    return _albums(body['hotAlbums'] ?? body['albums']);
  }

  /// 专辑详情. The unsigned `GET /api/album/{id}` is risk-controlled by NetEase
  /// (it answers 请绑定手机), so this goes through the signed v1 endpoint.
  static Future<({AlbumInfo album, List<Song> songs})> album(String id) async {
    final body = await WyNative.weapi({'id': id}, '/weapi/v1/album/$id');
    final album = AlbumInfo.fromNetEase(body['album'] as Map?);
    if (album == null) throw Exception('取不到这张专辑的信息');
    return (album: album, songs: _songs(body['songs']));
  }

  static List<Song> _songs(dynamic raw) => ((raw is List) ? raw : const [])
      .map(WySearch.parseSong)
      .whereType<Song>()
      .toList();

  static List<AlbumInfo> _albums(dynamic raw) => ((raw is List) ? raw : const [])
      .whereType<Map>()
      .map((e) => AlbumInfo.fromNetEase(e))
      .whereType<AlbumInfo>()
      .toList();

  static List<SheetInfo> _sheets(dynamic raw) {
    final list = (raw is List) ? raw : const [];
    return list.whereType<Map>().map((e) {
      final img = (e['picUrl'] ?? e['coverImgUrl'])?.toString();
      return SheetInfo(
        'wy',
        '${e['id']}',
        e['name']?.toString() ?? '',
        (img == null || img.isEmpty) ? null : img,
        (e['copywriter'] ?? e['description'] ?? '').toString().trim(),
        playCount: num.tryParse('${e['playCount'] ?? e['realPlayCount'] ?? 0}')?.toInt() ?? 0,
      );
    }).where((s) => s.id.isNotEmpty && s.name.isNotEmpty).toList();
  }

  /// Songs of one page of a playlist. v3 detail returns the *whole* id list
  /// whatever `n` says, so one cheap detail call plus a 50-id batch gives real
  /// pagination instead of the old hard 80-song cap.
  static Future<SearchResult> sheetSongs(String id, {int page = 1, int pageSize = 50}) async {
    final detail = await WyNative.getJson('/api/v3/playlist/detail', query: {'id': id, 'n': '1'});
    final pl = detail['playlist'] as Map?;
    final trackIds = (pl?['trackIds'] as List?) ?? const [];
    final allIds = trackIds
        .map((e) => (e as Map?)?['id'])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList();
    if (allIds.isEmpty) throw Exception('这个歌单里没有可播放的歌曲');
    final from = (page - 1) * pageSize;
    if (from >= allIds.length) return SearchResult(allIds.length, (allIds.length / pageSize).ceil(), const []);
    final ids = allIds.sublist(from, (from + pageSize) > allIds.length ? allIds.length : from + pageSize);
    final songs = <Song>[];
    for (var i = 0; i < ids.length; i += 50) {
      final chunk = ids.sublist(i, (i + 50) > ids.length ? ids.length : i + 50);
      final body = await WyNative.weapi({
        'c': '[${chunk.map((id) => '{"id":$id}').join(',')}]',
      }, '/weapi/v3/song/detail');
      songs.addAll(((body['songs'] as List?) ?? const []).map(WySearch.parseSong).whereType<Song>());
    }
    if (songs.isEmpty) throw Exception('歌单详情取不到歌曲，换一个试试');
    final total = (pl?['trackTotalCount'] as num?)?.toInt() ?? allIds.length;
    return SearchResult(total, (total / pageSize).ceil(), songs);
  }
}
