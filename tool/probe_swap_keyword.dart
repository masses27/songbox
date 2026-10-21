// 换源关键词到底搜得出什么：拿「高山青 (Live版)」这首对比收紧前后的两种写法。
// 用法：~/dev/flutter/bin/dart.bat run tool/probe_swap_keyword.dart
import 'dart:io';

import 'package:lyric_music/music_sdk/wy_search.dart';

final out = StringBuffer();
void p(String s) => out.writeln(s);

Future<void> main() async {
  for (final kw in [
    '高山青 (Live版) 那英、华晨宇、艾薇 Ivy', // 收紧前：整串歌手名一起丢进去
    '高山青 那英', // 现在这条链子实际发出去的：曲名 + 第一个歌手
    '高山青 那英、华晨宇、艾薇 Ivy',
  ]) {
    p('===== cloudsearch「$kw」 =====');
    try {
      final r = await WySearch().search(kw, limit: 10);
      for (final s in r.list) {
        p('  ${s.id} fee=${s.fee} ${s.name} | ${s.singer} | ${s.albumName}');
      }
      if (r.list.isEmpty) p('  （0 条）');
    } catch (e) {
      p('  抛：$e');
    }
  }
  File('C:/tmp/probe_swap_keyword.txt').writeAsStringSync(out.toString());
}
