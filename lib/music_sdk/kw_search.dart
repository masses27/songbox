import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';

/// Kuwo (kw) music search — ported from lx-music-mobile
/// `src/utils/musicSdk/kw/musicSearch.js`.
class KwSearch {
  static final RegExp _mInfo =
      RegExp(r'level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)');

  static String decodeName(String? str) {
    if (str == null || str.isEmpty) return '';
    return str
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }

  static String formatSinger(String raw) => raw.replaceAll('&', '、');

  Future<SearchResult> search(String keyword, {int page = 1, int limit = 30}) async {
    final url =
        'http://search.kuwo.cn/r.s?client=kt&all=${Uri.encodeQueryComponent(keyword)}'
        '&pn=${page - 1}&rn=$limit&uid=794762570&ver=kwplayer_ar_9.2.2.1'
        '&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012'
        '&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    final resp = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      responseType: ResponseType.plain,
    )).get<dynamic>(url);
    final body = resp.data;
    if (body is! String) throw Exception('kw search: unexpected response');
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final rawList = (decoded['abslist'] as List?) ?? const [];
    final list = <Song>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final song = _handleOne(Map<String, dynamic>.from(raw));
      if (song != null) list.add(song);
    }
    final total = int.tryParse('${decoded['TOTAL'] ?? '0'}') ?? list.length;
    return SearchResult(total, (total / limit).ceil().clamp(1, 9999), list);
  }

  Song? _handleOne(Map<String, dynamic> info) {
    final nMinfo = info['N_MINFO'];
    if (nMinfo is! String) return null;
    final songmid = (info['MUSICRID']?.toString() ?? '').replaceFirst('MUSIC_', '');
    final types = <String, SongQuality>{};
    for (final seg in nMinfo.split(';')) {
      final m = _mInfo.firstMatch(seg);
      if (m == null) continue;
      final bitrate = m.group(2);
      final size = m.group(4);
      switch (bitrate) {
        case '4000':
          types['flac24bit'] = SongQuality('flac24bit', size);
          break;
        case '2000':
          types['flac'] = SongQuality('flac', size);
          break;
        case '320':
          types['320k'] = SongQuality('320k', size);
          break;
        case '128':
          types['128k'] = SongQuality('128k', size);
          break;
      }
    }
    return Song(
      songmid: songmid,
      id: songmid,
      source: 'kw',
      name: decodeName(info['SONGNAME'] as String?),
      singer: formatSinger(decodeName(info['ARTIST'] as String?)),
      albumId: decodeName(info['ALBUMID'] as String?),
      albumName: decodeName(info['ALBUM'] as String?),
      pic: coverUrl(info['web_albumpic_short'] as String?),
      interval: int.tryParse('${info['DURATION'] ?? ''}') ?? 0,
      typeMap: types,
    );
  }

  /// 酷我给的是 `120/s3s94/93/xxx.jpg` 这种首段带尺寸的短路径，拼上域名才有封面。
  /// 首段换成 240/300/500 都能取到同一张图的不同尺寸，列表行用默认的 120。
  static String? coverUrl(String? short, {int size = 120}) {
    if (short == null || short.isEmpty) return null;
    final slash = short.indexOf('/');
    if (slash <= 0) return null;
    return 'https://img4.kuwo.cn/star/albumcover/$size/${short.substring(slash + 1)}';
  }
}
