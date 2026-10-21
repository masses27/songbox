// 一次性排查脚本：为什么「声生不息」这类 Live 版取到链接却放不出。
// 用法：~/dev/flutter/bin/dart.bat run tool/probe_live_versions.dart [搜索词…]
import 'dart:convert';
import 'dart:io';

import 'package:lyric_music/music_sdk/wy_native.dart';
import 'package:lyric_music/music_sdk/wy_search.dart';

final out = StringBuffer();
void p(String s) => out.writeln(s);

Future<void> main(List<String> args) async {
  for (final kw in args.isEmpty ? ['高山青'] : args) {
    p('===== 搜索「$kw」 =====');
    final r = await WySearch().search(kw, limit: 30);
    for (final s in r.list) {
      p('${s.id}  fee=${s.fee}  ${s.name}  | ${s.singer} | ${s.albumName} | ${s.interval}s');
    }
    for (final s in r.list.take(4)) {
      await probe('${s.id}', '${s.name} / ${s.singer}');
    }
  }
  File('C:/tmp/probe_live_versions.txt').writeAsStringSync(out.toString());
}

Future<void> probe(String id, String label) async {
  p('----- $id  $label -----');
  for (final br in [320000, 128000]) {
    try {
      final body = await WyNative.weapi({
        'ids': [id],
        'br': br,
      }, '/weapi/song/enhance/player/url');
      final data = body['data'];
      final first = (data is List && data.isNotEmpty) ? data.first : null;
      p('  url br=$br → code=${body['code']} ${first == null ? '无条目' : jsonEncode(first)}');
    } catch (e) {
      p('  url br=$br 抛：$e');
    }
  }
  try {
    final d = await WyNative.weapi({
      'c': jsonEncode([
        {'id': id}
      ]),
    }, '/weapi/v3/song/detail');
    final songs = (d['songs'] as List?) ?? const [];
    final datas = (d['data'] as List?) ?? const [];
    final s = songs.isEmpty ? null : songs.first as Map?;
    final pl = datas.isEmpty ? null : datas.first as Map?;
    p('  detail → fee=${s?['fee']} md=${s?['md5']} duration=${s?['dt']} '
        'privilege=${jsonEncode(pl?['privilege'])}');
  } catch (e) {
    p('  detail 抛：$e');
  }
}
