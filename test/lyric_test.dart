import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/models/results.dart';
import 'package:lyric_music/player/player_service.dart';

void main() {
  test('parse keeps timestamps and drops empty lines', () {
    final lines = LyricParser.parse('[00:01.50]第一句\n[00:02.00]\n[01:00]第二句');
    expect(lines.length, 2);
    expect(lines[0].timeMs, 1500);
    expect(lines[1].timeMs, 60000);
  });

  test('merge pairs a translation by nearest timestamp', () {
    // Real NetEase payloads: the original carries 作词/作曲 headers the
    // translation has no counterpart for, and the stamps drift by tens of ms.
    final lines = LyricParser.merge(LyricResult(
      lyric: '[00:00.000] 作词 : Richard Carpenter\n'
          '[00:02.879]When I was young\n'
          '[00:08.918]I\'d listen to the radio\n'
          '[03:20.000]Every song I like so many years ago',
      tlyric: '[00:02.900]我还年轻的时候\n[00:08.950]喜欢听收音机',
    ));
    expect(lines.length, 4);
    expect(lines[0].translated, isNull);
    expect(lines[1].translated, '我还年轻的时候');
    expect(lines[2].translated, '喜欢听收音机');
    expect(lines[3].translated, isNull);
  });

  test('merge leaves a single-language lyric untouched', () {
    final lines = LyricParser.merge(LyricResult(lyric: '[00:02.00]晴天', tlyric: '   '));
    expect(lines.single.translated, isNull);
  });
}
