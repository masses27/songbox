import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/player/audio_prefetch.dart';
import 'package:lyric_music/ui/pages/builtin_library.dart';
import 'package:lyric_music/ui/theme.dart';
import 'package:lyric_music/ui/widgets.dart';

void main() {
  test('formatPlayTime', () {
    expect(formatPlayTime(65), '01:05');
    expect(formatPlayTime(null), '--:--');
    expect(formatPlayTime(0), '00:00');
  });

  test('来源码都要有给人看的名字', () {
    // 会员墙后面的歌现在多半落在 B 站、酷狗那两条整首上，播放页和「找其他版本」都直接
    // 显示这个标签；漏一行就是给她看一个没见过的源码。
    expect(sourceLabel('wy'), '网易云');
    expect(sourceLabel('kw'), '酷我');
    expect(sourceLabel('tx'), 'QQ');
    expect(sourceLabel('bl'), 'B 站');
    expect(sourceLabel('kg'), '酷狗');
  });

  test('档位码也要有给人看的名字', () {
    // 以前只有设置页有一张对照表，播放页那行、下载确认、音源自检都直接把「flac」念出来。
    // 合成一份之后 B 站那一档必须照实写 192k：套进「高清 320k」就是吹。
    expect(qualityLabel('128k'), '标准 128k');
    expect(qualityLabel('320k'), '高清 320k');
    expect(qualityLabel('flac'), '无损 flac');
    expect(qualityLabel('192k'), '高清 192k');
    expect(qualityLabel(heardQuality('flac', 'bl')), '高清 192k');
  });

  test('档位标注写实际听到的那一档', () {
    // 换源/匿名兜底的那几条各有上限（B 站 192k、QQ 128k、酷狗 128k），永远到不了无损。
    // 播放页和下载弹窗都写设置值的话，「无损 flac · 免费版」挂在耳朵是 192k 那儿。
    expect(heardQuality('flac', 'bl'), '192k');
    expect(heardQuality('320k', 'bl'), '192k');
    expect(heardQuality('flac', 'tx'), '128k');
    expect(heardQuality('320k', 'kg'), '128k');
    expect(heardQuality('128k', 'bl'), '128k'); // 她要的比上限还低，别反过来吹成 192k
    expect(heardQuality('flac', 'wy'), 'flac');
  });

  test('预取文件名也按实际那一档存', () {
    // 同一首歌靠 B 站兜整首：键写设置里的无损，改一次音质就把同样的字节再下一遍，
    // 而且播放时按 192k 查不到磁盘上那份——「提前备好」等于没备。
    final wy = Song(source: 'wy', songmid: 'm1', name: '会员歌', fee: 1);
    expect(AudioPrefetch.key(wy, 'flac', servedBy: 'bl'), 'pf-wy-m1-192k');
    expect(AudioPrefetch.key(wy, '320k', servedBy: 'bl'), 'pf-wy-m1-192k');
    expect(AudioPrefetch.key(wy, 'flac'), 'pf-wy-m1-flac'); // 没换源：想要哪档存哪档
    expect(AudioPrefetch.key(Song(source: 'bl', songmid: 'BV1x', name: '整首'), 'flac'),
        'pf-bl-BV1x-192k');
  });

  test('匿名整首那几家：名字、档位上限、预取键、端内可取链一处都不许漏', () {
    // B 站之后又接了酷狗，要动的就是这四样。漏标注是骗她耳朵，漏预取键是把同一份
    // 字节按两个档名各存一遍，漏 inAppSources 是这类歌白跑一趟换源、连脚本都不给试。
    // 写成一张表跑一遍：以后再接一家只加一行，不用到处找漏了哪处。
    for (final (src, cap) in const [('bl', '192k'), ('kg', '128k'), ('tx', '128k')]) {
      expect(sourceLabel(src), isNot(src), reason: '$src 得有给人看的名字');
      expect(heardQuality('flac', src), cap, reason: '$src 匿名整首的上限');
      expect(
        AudioPrefetch.key(Song(source: 'wy', songmid: 'm', name: 'x'), 'flac', servedBy: src),
        'pf-wy-m-$cap',
        reason: '$src 兜底时预取要按实际那一档存文件',
      );
      expect(BuiltinLibrary.inAppSources, contains(src), reason: '$src 端内就能取链');
    }
  });

  testWidgets('无限宽的封面块（首页轮播）不会在 build 里炸掉', (tester) async {
    // size = double.infinity 时 (size * dpr).round() 抛 UnsupportedError，
    // release 下整个 banner 只剩空白，看起来就是「推荐页没有图」。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: CoverTile(label: '测试', imageUrl: null, size: double.infinity),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('测试'), findsOneWidget);
  });

  test('深浅两套色板各自成对，淡彩底在深色下只留色相', () {
    AppTheme.dark = true;
    expect(AppTheme.palette().scaffoldBackgroundColor, const Color(0xFF121212));
    expect(AppTheme.textPrimary, const Color(0xFFE6E6E6));
    expect(AppTheme.divider, const Color(0xFF2B2B2B));
    expect(AppTheme.tile(const Color(0xFFFFF1E0)).a, closeTo(.18, .001));

    AppTheme.dark = false;
    expect(AppTheme.palette().scaffoldBackgroundColor, Colors.white);
    expect(AppTheme.textPrimary, const Color(0xFF333333));
    expect(AppTheme.tile(const Color(0xFFFFF1E0)), const Color(0xFFFFF1E0));
  });
}
