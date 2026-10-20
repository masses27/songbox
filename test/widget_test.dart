import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/ui/theme.dart';
import 'package:lyric_music/ui/widgets.dart';

void main() {
  test('formatPlayTime', () {
    expect(formatPlayTime(65), '01:05');
    expect(formatPlayTime(null), '--:--');
    expect(formatPlayTime(0), '00:00');
  });

  test('来源码都要有给人看的名字', () {
    // 会员墙后面的歌现在多半落在 B 站那条整首上，播放页和「找其他版本」都直接
    // 显示这个标签；漏一行就是给她看一个没见过的源码。
    expect(sourceLabel('wy'), '网易云');
    expect(sourceLabel('kw'), '酷我');
    expect(sourceLabel('tx'), 'QQ');
    expect(sourceLabel('bl'), 'B 站');
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
