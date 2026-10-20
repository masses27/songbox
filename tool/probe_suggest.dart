// ignore_for_file: avoid_print

import 'package:lyric_music/music_sdk/wy_native.dart';

Future<void> main() async {
  final r = await WyNative.weapi({'frag': '0', 's': '周杰伦'}, '/weapi/search/suggest/web');
  final res = r['result'];
  print('result keys: ${(res as Map).keys.toList()}');
  for (final e in res.entries) {
    final v = e.value;
    print('-- ${e.key}: ${v.runtimeType} ${v.toString().substring(0, v.toString().length.clamp(0, 260))}');
  }
  final hot = await WyNative.weapi({'type': 1, 'apply': 0, 'time': '0'}, '/weapi/search/hot');
  final h = (hot['result'] as Map?)?['hots'];
  print('hot count: ${(h as List?)?.length} first: ${h?.take(3).toList()}');
}
