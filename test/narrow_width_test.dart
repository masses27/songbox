import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/ui/widgets.dart';

/// 桌面版能把窗口拖到 360 逻辑像素那么窄（runner 里 MinimumTrackSize 就收到这个数），
/// 跟手机一样宽。凡是「一行里塞一段长度由数据决定的文案」都得在这里摆得下——
/// 摆不下不是难看，是 RenderFlex 溢出：屏上多一道黄黑条，她得把窗口拉宽才看得见那行字。
void main() {
  Future<void> narrow(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
  }

  testWidgets('区块标题再长也只省略号，不许顶破一行', (tester) async {
    const long = '专辑 · 前 30 / 共 128 张（现场版）— 陶喆 & 张韶涵';
    await narrow(tester, SectionHeader(long, actionText: '换一批', onAction: () {}));

    expect(tester.takeException(), isNull);
    // 标题确实画出来了（被截断），右边那颗动作键也还在原位。
    expect(find.text(long), findsOneWidget);
    expect(find.text('换一批'), findsOneWidget);
    // Padding 左右各占掉 16/12：整行可用 332，标题不许越过它。
    expect(tester.getSize(find.text(long)).width, lessThanOrEqualTo(332.0));
    expect(tester.getTopRight(find.text('换一批')).dx, lessThanOrEqualTo(348.0));
  });

  // 播放页歌手名后面那一格：形状跟 lib/ui/player/player_page.dart 里一致
  // （Expanded 的歌手 + Flexible 里撑满、贴右的标签）。改这块的原因是窄窗 + 大字体
  // 时那半句标签会顶破一行；盯的是「不许溢出」和「标签仍贴右边缘」这两条。
  Future<void> singerRow(WidgetTester tester, String singer, String tag) async {
    await narrow(
      tester,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Expanded(
              child: Text(singer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
            Flexible(
              child: SizedBox(
                width: double.infinity,
                child: Text(tag,
                    maxLines: 1,
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('长合唱名 + 最长标签：谁都不许越出这一行', (tester) async {
    const singer = '陶喆、张韶涵、林俊杰、陈奕迅、王菲';
    const tag = '无损音质 · 本地文件 · 下载中 100%';
    await singerRow(tester, singer, tag);

    expect(tester.takeException(), isNull);
    // 可用宽度 = 360 − 左右各 24 = 312；两位各拿一半，都不许越线。
    for (final w in [find.text(singer), find.text(tag)]) {
      expect(tester.getSize(w).width, lessThanOrEqualTo(156.0));
    }
    expect(tester.getTopRight(find.text(tag)).dx, closeTo(336.0, 0.01));
  });

  testWidgets('标签短的时候仍贴右边缘，不往中间挪', (tester) async {
    await singerRow(tester, '周杰伦', '320k · 网易云');

    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(find.text('320k · 网易云')).dx, closeTo(336.0, 0.01));
    // 歌手名左边对齐，起点不变。
    expect(tester.getTopLeft(find.text('周杰伦')).dx, closeTo(24.0, 0.01));
  });
}
