import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';
import 'kw_search.dart';

/// Kuwo (kw) leaderboards — simplified port of lx-music-mobile's
/// `src/utils/musicSdk/kw/leaderboard.js` that uses the public
/// `kbangserver.kuwo.cn/ksong.s` endpoint (no AES/MD5 crypto needed).
class KwLeaderboard {
  static const List<RankInfo> _boards = [
    RankInfo('kw', '93', '飙升榜'),
    RankInfo('kw', '16', '热歌榜'),
    RankInfo('kw', '17', '新歌榜'),
    RankInfo('kw', '158', '抖音热歌榜'),
    RankInfo('kw', '26', '经典怀旧榜'),
    RankInfo('kw', '104', '华语榜'),
    RankInfo('kw', '182', '粤语榜'),
    RankInfo('kw', '22', '欧美榜'),
    RankInfo('kw', '184', '韩语榜'),
    RankInfo('kw', '183', '日语榜'),
    RankInfo('kw', '145', '会员畅听榜'),
    RankInfo('kw', '187', '流行趋势榜'),
  ];

  List<RankInfo> get list => _boards;

  Future<SearchResult> getList(String bangId, {int page = 1, int limit = 30}) async {
    final url = 'http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json'
        '&pn=${page - 1}&rn=$limit&type=bang&data=content&id=$bangId'
        '&show_copyright_off=0&pcmp4=1&isbang=1';
    final resp = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.plain,
    )).get<dynamic>(url);
    final body = resp.data;
    if (body is! String) throw Exception('kw rank: unexpected response');
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final rawList = (decoded['musiclist'] as List?) ?? const [];
    final list = <Song>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      list.add(_handleOne(Map<String, dynamic>.from(raw)));
    }
    final total = int.tryParse('${decoded['num'] ?? list.length}') ?? list.length;
    return SearchResult(total, (total / limit).ceil().clamp(1, 999), list);
  }

  Song _handleOne(Map<String, dynamic> info) {
    final songmid = info['id']?.toString() ?? '';
    final types = <String, SongQuality>{};
    final formats = (info['formats'] ?? '').toString();
    for (final f in formats.split('|')) {
      switch (f) {
        case 'MP3128':
          types['128k'] = SongQuality('128k');
          break;
        case 'MP3H':
          types['320k'] = SongQuality('320k');
          break;
        case 'ALFLAC':
          types['flac'] = SongQuality('flac');
          break;
        case 'ZPLY':
        case 'BCMS':
          types['flac24bit'] = SongQuality('flac24bit');
          break;
      }
    }
    return Song(
      songmid: songmid,
      id: songmid,
      source: 'kw',
      name: KwSearch.decodeName(info['name'] as String?),
      singer: KwSearch.formatSinger(KwSearch.decodeName(info['artist'] as String?)),
      albumId: info['albumid']?.toString(),
      albumName: KwSearch.decodeName(info['album'] as String?),
      interval: int.tryParse('${info['song_duration'] ?? info['duration'] ?? ''}') ?? 0,
      typeMap: types,
    );
  }
}
