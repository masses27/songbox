import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';

/// NetEase (wy) official toplists: board list + board songs.
class WyLeaderboard {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    headers: const {
      'User-Agent': 'Mozilla/5.0',
      'Referer': 'https://music.163.com/',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
  ));

  Future<List<RankInfo>> get list async {
    final resp = await _dio.get('https://music.163.com/api/toplist?csrf_token=');
    final j = jsonDecode(resp.data as String);
    final arr = ((j as Map)['list']) as List? ?? const [];
    return arr.map((e) {
      final m = e as Map;
      final pic = m['coverImgUrl']?.toString() ?? '';
      // description 是整段榜单介绍，卡片上只要一行；更新频率拼在后面更有用。
      final freq = m['updateFrequency']?.toString() ?? '';
      final desc = '${m['description'] ?? ''}'.trim();
      final short = desc.length > 30 ? '${desc.substring(0, 30)}…' : desc;
      return RankInfo(
        'wy',
        '${m['id']}',
        '${m['name'] ?? ''}',
        img: pic.isEmpty ? null : pic,
        desc: freq.isEmpty ? short : (short.isEmpty ? freq : '$short · $freq'),
      );
    }).toList();
  }

  /// One page of a board. The detail call hands back every trackId whatever `n`
  /// says, so slicing them is what makes 上滑翻页 real instead of repeating the
  /// same 200 songs on every page.
  static const _pageSize = 50;

  Future<SearchResult> getList(String rankId, {int page = 1}) async {
    final resp = await _dio.post(
      'https://music.163.com/api/v3/playlist/detail?id=$rankId&n=1&csrf_token=',
      data: 'id=$rankId',
    );
    final j = jsonDecode(resp.data as String);
    final pl = (j as Map)['playlist'];
    final trackIds = (pl is Map ? pl['trackIds'] : null) as List? ?? const [];
    final all = trackIds.map((t) => '${(t as Map)['id']}').toList();
    if (all.isEmpty) return SearchResult(0, 1, const []);
    final from = (page - 1) * _pageSize;
    if (from >= all.length) return SearchResult(all.length, (all.length / _pageSize).ceil(), const []);
    final ids = all.sublist(from, (from + _pageSize) > all.length ? all.length : from + _pageSize);
    final songs = await _detail(ids);
    final total = (pl is Map && pl['trackTotalCount'] is num)
        ? (pl['trackTotalCount'] as num).toInt()
        : all.length;
    return SearchResult(total, (total / _pageSize).ceil(), songs);
  }

  Future<List<Song>> _detail(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final c = ids.map((i) => {'id': int.tryParse(i) ?? 0}).toList();
    final resp = await _dio.post(
      'https://music.163.com/api/v3/song/detail?csrf_token=',
      data: 'c=${Uri.encodeQueryComponent(jsonEncode(c))}&ids=[${ids.join(',')}]',
    );
    final j = jsonDecode(resp.data as String);
    final arr = ((j as Map)['songs']) as List? ?? const [];
    return arr.map(_one).whereType<Song>().toList();
  }

  static Song? _one(dynamic s) {
    if (s is! Map) return null;
    final id = '${s['id']}';
    final ar = (s['ar'] as List?) ?? (s['artists'] as List?);
    final artists = ar?.map((a) => '${(a as Map)['name']}').join('、') ?? '';
    final album = s['album'] as Map?;
    final dur = (s['dt'] as num?)?.toInt() ?? (s['duration'] as num?)?.toInt() ?? 0;
    return Song(
      songmid: id,
      id: id,
      source: 'wy',
      name: '${s['name'] ?? ''}',
      singer: artists,
      albumId: '${album?['id'] ?? ''}',
      albumName: '${album?['name'] ?? ''}',
      pic: album?['picUrl']?.toString(),
      interval: dur ~/ 1000,
      fee: (s['fee'] as num?)?.toInt() ?? 0,
    );
  }
}
