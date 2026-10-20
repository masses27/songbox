// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:lyric_music/music_sdk/wy_native.dart';
import 'package:lyric_music/music_sdk/wy_search.dart';

/// Prints the raw field names of NetEase's lyric payload so the translation
/// track can be read from the right place. Run: dart run tool/probe_lyric.dart
Future<void> main(List<String> args) async {
  final ids = <String>[];
  if (args.isNotEmpty) {
    ids.addAll(args);
  } else {
    for (final kw in const ['Yesterday Once More', 'See You Again', ' Lemon 米津玄師']) {
      final r = await WySearch().search(kw, limit: 5);
      ids.addAll(r.list.map((s) => s.songmid));
      print('# $kw -> ${r.list.map((s) => '${s.name}/${s.songmid}').join(', ')}');
    }
  }
  for (final id in ids) {
    print('--- $id');
    try {
      final body = await WyNative.weapi({
        'id': id,
        'tv': -1,
        'lv': -1,
        'rv': -1,
        'kv': -1,
      }, '/weapi/song/lyric');
      print('top keys: ${body.keys.toList()}');
      for (final e in body.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final text = v['lyric'] ?? v['tlyric'];
        final head = text is String && text.trim().isNotEmpty
            ? ' head=${jsonEncode(text.substring(0, text.length > 90 ? 90 : text.length))}'
            : '';
        print('${e.key}: keys=${v.keys.toList()}$head');
      }
    } catch (err) {
      print('error: $err');
    }
  }
}
