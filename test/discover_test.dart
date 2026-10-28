import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/ui/pages/discover_page.dart';

/// 发现页的布局冒烟测。
///
/// 这一页的接口在测试里是打不通的（flutter_test 把 HttpClient 换成了回 400 的假货），
/// 所以歌单和榜单两块都会落到报错那一格——这里要看的本来也不是数据，是那两块新的控件
/// 在 360 宽的屏上摆得下摆不下：分类面板展开、收起对不对，有没有溢出报错。
void main() {
  Future<void> openPanel(WidgetTester tester) async {
    await tester.dragUntilVisible(find.text('全部分类'), find.byType(ListView).first, const Offset(-120, 0));
    await tester.pump();
    await tester.tap(find.text('全部分类'));
    await tester.pump();
  }

  /// 把页面滚到某个控件那里。
  ///
  /// 这一页往下两三屏才到底，`find.text` 默认把整块不在台上的 sliver 滤掉（返回 0 个），
  /// `tap` 也会算出一个屏外的点、点了个空。所以先看真的（skipOffstage: false）确有其物，
  /// 再滚过去，之后按她屏幕上真看得见的那个 finder 断言。
  Future<void> reveal(WidgetTester tester, String label) async {
    final real = find.text(label, skipOffstage: false);
    expect(real, findsOneWidget, reason: '「$label」根本没被建出来，滚过去也没有');
    await tester.ensureVisible(real);
    await tester.pump();
  }

  /// 在飞的请求把超时定时器留在 fake clock 上，不收尾的话测试结束就报「还有 Timer」。
  Future<void> drain(WidgetTester tester) => tester.pump(const Duration(seconds: 30));

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DiscoverPage())));
    await tester.pump();
  }

  testWidgets('横向那一排末尾有「全部分类」，摊开能看到收起来的词', (tester) async {
    await pumpPage(tester);
    expect(find.text('歌单分类'), findsOneWidget);
    // 那颗排在分类行末尾，得先把那一行划到头。
    await openPanel(tester);
    expect(find.text('语种'), findsOneWidget);
    // 挑「器乐」而不是随手一个词：它是官方树上的，2026-10-29 实测有货，
    // 而像「意大利语」那种死词已经被从词表里删掉了——测试要是还写着它，
    // 就等于在替一块点了没内容的分类把关。
    await reveal(tester, '器乐');
    expect(find.text('意大利语'), findsNothing, reason: '死词不该再出现在界面上');
    expect(find.text('收起分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('分类面板摊开是一团小胶囊，不是一屏一个大按钮', (tester) async {
    await pumpPage(tester);
    await openPanel(tester);
    // Container(alignment:) 会让胶囊撑满整行宽：Wrap 一行就只放得下一颗，70 个词竖着
    // 排出去两屏多，「全部分类」点开变成一大屏按钮。量两个数：一颗胶囊自己多宽
    // （撑满就是 328），以及第一个分组标题到最后一个词跨了多高（撑满时两千多）。
    await reveal(tester, '器乐');
    final pill = tester
        .getRect(find.ancestor(of: find.text('器乐'), matching: find.byType(GestureDetector)).first);
    expect(pill.width, lessThan(120), reason: '「器乐」这颗占满 ${pill.width.toInt()} 宽，一行只剩它一个');
    final first = tester.getRect(find.text('语种'));
    expect(pill.top - first.top, lessThan(900),
        reason: '五个分组到最后一个词排了 ${(pill.top - first.top).toInt()} 高，又是竖着一列大按钮');
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('在面板里挑一个分类，面板自己收起', (tester) async {
    await pumpPage(tester);
    await openPanel(tester);
    await reveal(tester, '器乐');
    await tester.tap(find.text('器乐'));
    await tester.pump();
    expect(find.text('语种'), findsNothing, reason: '挑完还摊着的话，歌单永远被压在面板下面');
    expect(find.text('全部分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('歌单那一块不摆排序开关', (tester) async {
    await pumpPage(tester);
    await openPanel(tester);
    await reveal(tester, '器乐');
    await tester.tap(find.text('器乐'));
    await tester.pump();
    // 2026-10-29 探过：`collect` 换出来的那批不按收藏数排（华语头一条 738、第六条 13 万），
    // `hot` 也不按播放数排，`new` 直接回空。名字说不出真话的开关不如不做，
    // 这一条留着是免得下一轮又把它当「新功能」加回来。
    expect(find.text('排序', skipOffstage: false), findsNothing);
    expect(find.text('最热', skipOffstage: false), findsNothing);
    expect(find.text('收藏最多', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('还没听出口味时「按你的口味」那一排不出现', (tester) async {
    await pumpPage(tester);
    // 这一排的候选池是从她听得最多的那几位搜出来的；测试这台机器上一条记录都没有，
    // 板块就该整块消失，而不是摆一个「没拉到」在那里。
    expect(find.text('按你的口味', skipOffstage: false), findsNothing);
    expect(find.text('新歌速递'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('榜单源三颗胶囊摆得下，QQ 是这一轮新接的那家', (tester) async {
    await pumpPage(tester);
    await reveal(tester, 'QQ');
    expect(find.text('网易云'), findsOneWidget);
    expect(find.text('酷我'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });

  testWidgets('接口回不来时这一页不炸，也不铺分组标题', (tester) async {
    await pumpPage(tester);
    await reveal(tester, '榜单');
    // 原来 60 多个榜全铺的时候，光分组标题就有四行，这一页要滚三屏才到得了榜单。
    expect(find.text('风格榜'), findsNothing);
    expect(find.text('海外榜'), findsNothing);
    expect(tester.takeException(), isNull);
    await drain(tester);
  });
}
