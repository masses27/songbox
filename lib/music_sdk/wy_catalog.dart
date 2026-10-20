import '../models/results.dart';
import '../models/song.dart';
import 'wy_native.dart';
import 'wy_search.dart';

/// NetEase recommendation / playlist catalog. Uses the same on-device weapi
/// signing as playback, so no bridge service is involved.
class WyCatalog {
  /// Stable playlist taxonomy from the NetEase web player.
  static const categories = [
    '推荐', '华语', '欧美', '日语', '韩语', '古风',
    '说唱', '电子', '流行', 'R&B', '轻音乐', '影视原声',
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

  /// 热门歌单 for a category tab.
  static Future<List<SheetInfo>> hotSheets(String category, {int page = 1, int limit = 30}) async {
    final body = await WyNative.getJson('/api/playlist/list', query: {
      'cat': category,
      'order': 'hot',
      'limit': '$limit',
      'offset': '${(page - 1) * limit}',
    });
    return _sheets(body['playlists']);
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
