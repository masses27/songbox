// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:lyric_music/music_sdk/wy_native.dart';

/// One-off discovery probe for the NetEase catalog endpoints batch 2 needs.
/// Run: dart run tool/probe_wy.dart
final _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 20),
  responseType: ResponseType.plain,
  headers: const {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    'Referer': 'https://music.163.com/',
    'Content-Type': 'application/x-www-form-urlencoded',
  },
));

Future<Map?> get(String url, {Map<String, String>? query, String? body}) async {
  try {
    final resp = body == null
        ? await _dio.get(url, queryParameters: query)
        : await _dio.post(url, queryParameters: query, data: body);
    final j = jsonDecode(resp.data as String);
    return j is Map ? j : null;
  } catch (e) {
    print('  !! $url -> $e');
    return null;
  }
}

void shape(String label, Map? j, {int preview = 260}) {
  print('== $label');
  if (j == null) return print('  (null)');
  final s = jsonEncode(j);
  print('  keys: ${j.keys.toList()}');
  print('  raw: ${s.length > preview ? s.substring(0, preview) : s}');
}

Future<void> main() async {
  shape('toplist', await get('https://music.163.com/api/toplist?csrf_token='));
  final boards = (await get('https://music.163.com/api/toplist?csrf_token='))?['list'];
  if (boards is List) {
    print('  names: ${boards.map((b) => (b as Map)['name']).toList()}');
  }

  for (final type in const [1, 10, 100, 1000]) {
    final r = await get('https://music.163.com/api/search/get/web?csrf_token=',
        body: 's=${Uri.encodeQueryComponent('陈奕迅')}&type=$type&offset=0&limit=3');
    shape('search type=$type', r, preview: 500);
  }

  final albumSearch = await get('https://music.163.com/api/search/get/web?csrf_token=',
      body: 's=${Uri.encodeQueryComponent('范特西')}&type=10&offset=0&limit=3');
  shape('album search(范特西)', albumSearch, preview: 500);
  final albumId = (((albumSearch?['result'] as Map?)?['albums'] as List?)?.first as Map?)?['id'];
  print('albumId: $albumId');
  shape('album/\$id', await get('https://music.163.com/api/album/$albumId'), preview: 700);

  // The plain GET above is risk-controlled, so try the signed shapes.
  for (final path in ['/weapi/v1/album/$albumId', '/weapi/album/$albumId', '/weapi/album']) {
    try {
      final b = await WyNative.weapi({'id': '$albumId'}, path);
      shape('weapi $path', b, preview: 500);
    } catch (e) {
      print('== weapi $path -> $e');
    }
  }
}
