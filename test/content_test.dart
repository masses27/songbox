import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/library/taste_profile.dart';
import 'package:lyric_music/models/results.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/music_sdk/wy_catalog.dart';
import 'package:lyric_music/music_sdk/wy_search.dart';
import 'package:lyric_music/ui/rank_groups.dart';
import 'package:lyric_music/util/humanize.dart';

RankInfo _r(String name) => RankInfo('wy', name, name);

void main() {
  group('groupRanks', () {
    // 真实接口返回 60+ 个榜，这里用其中一段代表各种命名陷阱。
    final ranks = [
      _r('飙升榜'), _r('新歌榜'), _r('原创榜'), _r('热歌榜'),
      _r('网易云古典榜'), _r('网易云电音榜'), _r('网易云中文说唱榜'), _r('网易云ACG榜'),
      _r('网易云欧美热歌榜'), _r('KTV唛榜'), _r('中文慢摇DJ榜'),
      _r('UK排行榜周榜'), _r('美国Billboard榜'), _r('日本Oricon榜'), _r('韩国Melon榜'),
      _r('网易云韩语榜'), _r('泰语榜'), _r('越南语榜'), _r('法国 NRJ Vos Hits 周榜'),
      _r('黑胶VIP爱听榜'), _r('网络热歌榜'), _r('黑胶VIP新歌榜'),
      _r('喜力®星电音派对潮音榜'), _r('特斯拉车友爱听榜'), _r('实时热度榜'),
    ];
    final byTitle = {for (final g in groupRanks(ranks)) g.title: g.ranks.map((e) => e.name).toList()};

    test('官方四大榜精确匹配，衍生榜不会被抬进主榜', () {
      expect(byTitle['官方主榜'], ['飙升榜', '新歌榜', '原创榜', '热歌榜']);
      expect(byTitle['风格榜'], isNot(contains('网络热歌榜')));
      expect(byTitle['其他榜单'], containsAll(['网络热歌榜', '黑胶VIP新歌榜', '实时热度榜']));
    });

    test('风格榜只收风格，品牌活动榜留在其他', () {
      expect(byTitle['风格榜'], containsAll(['网易云古典榜', '网易云电音榜', '网易云ACG榜', 'KTV唛榜', '中文慢摇DJ榜', '网易云欧美热歌榜']));
      expect(byTitle['其他榜单'], containsAll(['喜力®星电音派对潮音榜', '特斯拉车友爱听榜', '黑胶VIP爱听榜']));
    });

    test('海外与语种榜单独成组', () {
      expect(byTitle['海外榜'], containsAll(['美国Billboard榜', '日本Oricon榜', '泰语榜', '越南语榜', '网易云韩语榜', '法国 NRJ Vos Hits 周榜']));
    });

    test('空列表不产生空分组', () {
      expect(groupRanks(const []), isEmpty);
    });

    test('首页榜单只取官方主榜', () {
      expect(homeRanks(ranks), hasLength(4));
      expect(homeRanks([_r('某个新榜'), _r('另一个榜')]).map((e) => e.name), ['某个新榜', '另一个榜']);
    });
  });

  group('今日私荐的挑选', () {
    final pool = List.generate(30, (i) => Song(songmid: '$i', name: '歌$i'));

    test('还没听出口味时，同一天抽到的批次固定', () {
      final a = Taste.empty.rank(pool, count: 12, at: DateTime(2026, 10, 14));
      final b = Taste.empty.rank(pool, count: 12, at: DateTime(2026, 10, 14));
      expect(a.map((e) => e.songmid), b.map((e) => e.songmid));
      expect(a, hasLength(12));
      expect(pool.map((e) => e.songmid), List.generate(30, (i) => '$i')); // 不打乱原池
    });

    test('换一天就换一批', () {
      final a = Taste.empty.rank(pool, count: 12, at: DateTime(2026, 10, 14));
      final b = Taste.empty.rank(pool, count: 12, at: DateTime(2026, 10, 15));
      expect(a.map((e) => e.songmid).toList(), isNot(equals(b.map((e) => e.songmid).toList())));
    });

    test('池子不足时原样返回', () {
      expect(Taste.empty.rank(pool.take(5).toList(), count: 12), hasLength(5));
    });

    test('反复听完的那位歌手，新歌会排到前面', () {
      final now = DateTime(2026, 10, 21);
      final liked = Song(source: 'wy', songmid: 'a', name: '她听过的', singer: '陈绮贞', interval: 200);
      final taste = Taste.from(
        favorites: const [],
        recent: [liked],
        playlistSongs: const [],
        stats: {
          'wy:a': (plays: 4, done: 3, heard: 200, at: now.millisecondsSinceEpoch)
        },
        at: now,
      );
      final cands = [
        Song(source: 'wy', songmid: 'x', name: '别人的歌', singer: '某人'),
        Song(source: 'wy', songmid: 'y', name: '陈绮贞新歌', singer: '陈绮贞'),
      ];
      expect(taste.rank(cands, count: 1, at: now).single.songmid, 'y');
      expect(taste.topArtists(), ['陈绮贞']);
    });

    test('界面上报的是她见过的那个写法，匹配才忽略大小写', () {
      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: const [],
        recent: [Song(source: 'wy', songmid: 'b', name: 'Someone Like You', singer: 'ADELE')],
        playlistSongs: [Song(source: 'wy', songmid: 'a', name: 'Rolling in the Deep', singer: 'Adele')],
        stats: {
          'wy:b': (plays: 2, done: 0, heard: 0, at: now.millisecondsSinceEpoch),
        },
        at: now,
      );
      expect(taste.artists.keys, ['adele'], reason: '两个写法要算成同一个人');
      expect(taste.topArtists(), ['Adele']);
    });

    test('合作曲里每个署名都算一份', () {      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: [Song(source: 'wy', songmid: 'a', name: '合唱', singer: '王力宏、张靓颖')],
        recent: const [],
        playlistSongs: const [],
        stats: const {},
        at: now,
      );
      expect(taste.artists.keys, containsAll(['王力宏', '张靓颖']));
    });

    test('半年前沉迷过的人，不该还占着今天的位置', () {
      final now = DateTime(2026, 10, 21);
      double weightAt(int daysAgo) {
        final t = Taste.from(
          favorites: const [],
          recent: [Song(source: 'wy', songmid: 'a', name: '老歌', singer: '某人', interval: 200)],
          playlistSongs: const [],
          stats: {
            'wy:a': (plays: 3, done: 1, heard: 200, at: now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch)
          },
          at: now,
        );
        return t.artists['某人']!;
      }

      expect(weightAt(1), greaterThan(weightAt(120)));
    });

    test('听得很熟的歌不再端上来，同歌手的新歌照样上来', () {
      final now = DateTime(2026, 10, 21);
      final heard = Song(source: 'wy', songmid: 'a', name: '听了八遍', singer: '某人', interval: 200);
      final taste = Taste.from(
        favorites: const [],
        recent: [heard],
        playlistSongs: const [],
        stats: {
          'wy:a': (plays: 8, done: 4, heard: 200, at: now.millisecondsSinceEpoch)
        },
        at: now,
      );
      expect(taste.wornOut, contains('wy:a'));
      final ranked = taste.rank([
        Song(source: 'wy', songmid: 'b', name: '某人的新歌', singer: '某人'),
        Song(source: 'wy', songmid: 'c', name: '路人歌', singer: '路人'),
        heard,
      ], count: 2, at: now);
      expect(ranked.map((e) => e.songmid).toList(), contains('b'));
      expect(ranked.map((e) => e.songmid).toList(), isNot(contains('a')));
    });

    test('整池都听厌了也不能空着：宁可重复', () {
      final now = DateTime(2026, 10, 21);
      Song old(String id) =>
          Song(source: 'wy', songmid: id, name: '老歌$id', singer: '某人', interval: 200);
      final taste = Taste.from(
        favorites: const [],
        recent: [old('a'), old('b')],
        playlistSongs: const [],
        stats: {
          'wy:a': (plays: 8, done: 4, heard: 200, at: now.millisecondsSinceEpoch),
          'wy:b': (plays: 7, done: 3, heard: 200, at: now.millisecondsSinceEpoch),
        },
        at: now,
      );
      expect(taste.wornOut.length, 2);
      expect(taste.rank([old('a'), old('b')], count: 1, at: now), hasLength(1));
    });

    test('昨天刚听过的歌今天不再端上来，隔了五天的还算新鲜', () {
      final now = DateTime(2026, 10, 21);
      Song s(String id) => Song(source: 'wy', songmid: id, name: '歌$id', singer: '某人', interval: 200);
      final taste = Taste.from(
        favorites: const [],
        recent: [s('a'), s('c')],
        playlistSongs: const [],
        stats: {
          'wy:a': (plays: 1, done: 0, heard: 30, at: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch),
          'wy:c': (plays: 1, done: 0, heard: 30, at: now.subtract(const Duration(days: 5)).millisecondsSinceEpoch),
        },
        at: now,
      );
      expect(taste.heardRecently.toList(), ['wy:a']);
      expect(taste.rank([s('a'), s('b')], count: 1, at: now).single.songmid, 'b');
      expect(taste.rank([s('a'), s('c')], count: 1, at: now).single.songmid, 'c');
    });

    test('被挤出最近播放的老记录也算进口味，只要计数里还带着名字', () {
      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: const [],
        recent: const [],
        playlistSongs: const [],
        stats: {
          'wy:z': (
            plays: 3,
            done: 2,
            heard: 200,
            at: now.subtract(const Duration(days: 30)).millisecondsSinceEpoch
          ),
        },
        backfill: {'wy:z': (singer: '某人', interval: 200)},
        at: now,
      );
      expect(taste.artists['某人'], greaterThan(0));
      expect(taste.topArtists(), ['某人']);
      // 时长也是靠这一份补回来的：整首听完过两遍，早该算听厌了。
      expect(taste.wornOut, contains('wy:z'));
    });

    test('一位歌手最多占三首：偏一位不该让半屏都是同一个人', () {
      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: [Song(source: 'wy', songmid: 'a', name: '她的歌', singer: '某人')],
        recent: const [],
        playlistSongs: const [],
        stats: const {},
        at: now,
      );
      final ranked = taste.rank([
        for (var i = 0; i < 6; i++) Song(source: 'wy', songmid: 'p$i', name: '某人新歌$i', singer: '某人'),
        for (var i = 0; i < 6; i++) Song(source: 'wy', songmid: 'q$i', name: '路人歌$i', singer: '路人'),
      ], count: 6, at: now);
      expect(ranked.where((e) => e.singer == '某人'), hasLength(3));
      expect(ranked.where((e) => e.singer == '路人'), hasLength(3));
    });

    test('池子里只有那一位歌手时也填满，上限不该饿死一屏', () {
      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: [Song(source: 'wy', songmid: 'a', name: '她的歌', singer: '某人')],
        recent: const [],
        playlistSongs: const [],
        stats: const {},
        at: now,
      );
      final ranked = taste.rank([
        for (var i = 0; i < 6; i++) Song(source: 'wy', songmid: 'p$i', name: '某人新歌$i', singer: '某人'),
      ], count: 5, at: now);
      expect(ranked, hasLength(5));
    });

    test('两份名单里的同一首只占一个位置', () {
      final now = DateTime(2026, 10, 21);
      final dup = Song(source: 'wy', songmid: 'a', name: '同一首');
      final ranked = Taste.empty.rank([
        dup,
        dup,
        for (var i = 0; i < 12; i++) Song(source: 'wy', songmid: 'b$i', name: '歌$i'),
      ], count: 12, at: now);
      expect(ranked, hasLength(12));
      expect(ranked.map((e) => e.songmid).toSet(), hasLength(12), reason: '新歌位和榜单是两份名单，同一首常两边都在');
    });

    test('会员墙后面的歌扣分：这台手机上它多半要绕一整条换源链子', () {
      final now = DateTime(2026, 10, 21);
      final taste = Taste.from(
        favorites: const [],
        recent: const [],
        playlistSongs: const [],
        stats: const {},
        at: now,
      );
      expect(
        taste.scoreOf(Song(source: 'wy', songmid: 'v', name: '会员歌', singer: '某人', fee: 1)),
        lessThan(taste.scoreOf(Song(source: 'wy', songmid: 'f', name: '免费歌', singer: '某人'))),
      );
      // 已经找到免费版的就别再压：那些一按就出声，压下去把她常听的那几位挤出屏幕。
      expect(
        taste.scoreOf(Song(source: 'wy', songmid: 'v', name: '会员歌', singer: '某人', fee: 1),
            swapReady: (_) => true),
        taste.scoreOf(Song(source: 'wy', songmid: 'f', name: '免费歌', singer: '某人')),
      );
    });
  });

  group('歌单分类词表', () {
    // 分类树接口匿名全 404，词表只能带在端内；带进来的每一个词都要真的能问出歌单，
    // 否则点中那一格就是给她看一块「没拉到」。
    test('横向那一排用到的分类都在分组词表里', () {
      final grouped = WyCatalog.categoryGroups.expand((g) => g.names).toSet();
      for (final c in WyCatalog.quickCategories) {
        if (c == '推荐') continue; // 推荐不是分类，走的是个性化接口
        expect(grouped, contains(c), reason: '$c 排在哪一排，就该在词表里有那一项');
      }
      expect(WyCatalog.quickCategories.first, '推荐');
    });

    test('一个词不在两组里出现两次', () {
      final all = WyCatalog.categoryGroups.expand((g) => g.names).toList();
      expect(all.toSet(), hasLength(all.length), reason: '同一个分类挂两组，面板上就有两颗一样的胶囊');
      for (final g in WyCatalog.categoryGroups) {
        expect(g.names, isNotEmpty, reason: '${g.title} 这一组是空的，摊开只会是一行标题');
        expect(g.title, isNot(contains('推荐')));
      }
    });

    test('「推荐」不混进分类词表', () {
      // 它是界面自己排的第一格；混进词表的话「换一批」会拿它去问分类接口。
      expect(WyCatalog.categoryGroups.expand((g) => g.names), isNot(contains('推荐')));
    });
  });

  group('收藏的歌单', () {
    test('存出去取得回', () {
      final sheet = SheetInfo('wy', '123456', '华语私享', 'https://p1.music.126.net/ab==/3.jpg',
          '一人一票选出来的', playCount: 12345678);
      final back = SheetInfo.fromJson(jsonDecode(jsonEncode(sheet.toJson())));
      expect(back.source, 'wy');
      expect(back.name, '华语私享');
      expect(back.img, 'https://p1.music.126.net/ab==/3.jpg', reason: '== 是签名的一部分，落盘不能改写');
      expect(back.desc, '一人一票选出来的');
      expect(back.playCount, 12345678, reason: '卡片上的播放量不能一存一读就没了');
    });

    test('去重键带上曲库，不同源的同名 id 不会互相顶掉', () {
      expect(SheetInfo('wy', '1', 'A', null, null).key, 'wy:1');
      expect(SheetInfo('wy', '1', 'A', null, null).key, isNot(SheetInfo('kw', '1', 'A', null, null).key));
    });
  });

  group('播放量写法', () {
    test('一万以下原样，往上换成万和亿', () {
      expect(fmtCount(9999), '9999');
      expect(fmtCount(10000), '1万');
      expect(fmtCount(1234567), '123.5万');
      expect(fmtCount(1234567890), '12.3亿');
    });
  });

  group('网易云搜索结果的读法', () {
    // 2026-10-20 实测：老接口 `/api/search/get/web` 按出口 IP 风控，连打十几个词之后
    // 对**所有**关键词一律回 code:405 且不带 result（「晴天」「周杰伦」也一样）；
    // 换成网页版自己在用的 `/api/cloudsearch/pc`，匿名连打几十次全 200，结果数一致。
    // 它给的是 v3 那套短字段名，跟老接口不是一套。
    final cloudSong = {
      'id': 2652820720,
      'name': '晴天(深情版)',
      'ar': [
        {'id': 96154669, 'name': 'Lucky小爱', 'tns': [], 'alias': []}
      ],
      'al': {
        'id': 255723258,
        'name': '晴天(深情版)',
        'picUrl': 'http://p1.music.126.net/x/109951173569626660.jpg'
      },
      'dt': 278961,
      'fee': 8,
    };

    test('ar/al/dt 读得出来，时长换算成秒', () {
      final song = WySearch.parseSong(cloudSong)!;
      expect(song.songmid, '2652820720');
      expect(song.name, '晴天(深情版)');
      expect(song.singer, 'Lucky小爱');
      expect(song.source, 'wy');
      expect(song.interval, 278);
      expect(song.pic, contains('109951173569626660'));
    });

    test('只有 fee=1 算撞墙，8 实测照样出链', () {
      expect(WySearch.parseSong({...cloudSong, 'fee': 8})!.needsVip, isFalse);
      expect(WySearch.parseSong({...cloudSong, 'fee': 0})!.needsVip, isFalse);
      expect(WySearch.parseSong({...cloudSong, 'fee': 1})!.needsVip, isTrue);
    });

    test('专辑的 artist 是个空壳时，真名从 artists 里取', () {
      // cloudsearch 的 album.artist 是 {name:'', id:0}：`??` 兜不住空串，
      // 照原来的写法专辑行会连歌手名都不显示。
      final album = AlbumInfo.fromNetEase({
        'id': 372081313,
        'name': '叶惠美',
        'picUrl': 'https://p1.music.126.net/y/1.jpg',
        'artist': {'name': '', 'id': 0},
        'artists': [
          {'name': '王珏子乔', 'id': 0}
        ],
        'size': 18,
      })!;
      expect(album.artist, '王珏子乔');
      // id 为 0 等于没给：宁可不给歌手页入口，也别跳去一个空页。
      expect(album.artistId, isEmpty);
    });

    test('artist 有真名真号时照旧用它', () {
      final album = AlbumInfo.fromNetEase({
        'id': 372081313,
        'name': '叶惠美',
        'artist': {'name': '周杰伦', 'id': 7},
      })!;
      expect(album.artist, '周杰伦');
      expect(album.artistId, '7');
    });

    test('限流的回执算「接口没答话」，不算「没有这首歌」', () {
      // 这几句是 WySearch._post 抛出来的原文：换源那条链子认「被限流」这个标记，
      // 限流时不会把这首歌打上「确认没有免费版」的标（那一打就是一周）。
      expect(looksLikeThrottle('网易云搜索被限流：code=405 且没带结果，过一会儿再试'), isTrue);
      expect(looksLikeThrottle('网易云搜索被限流：回的不是 JSON（HTTP 200）'), isTrue);
      expect(looksLikeThrottle('网易云搜索没有这首歌'), isFalse);
      // 各家接口的风控页都长这样：回的压根不是 JSON，只能落到「返回异常」这一句上。
      // 判成「这首真的没有」的话，一首好歌要被跳过一周。
      expect(looksLikeThrottle('网易云接口返回异常（HTTP 200）'), isTrue);
      expect(looksLikeThrottle('B 站播放 返回异常（HTTP 200）'), isTrue);
      expect(looksLikeThrottle('B 站播放 回 code -352：风控校验失败'), isTrue);
      // 接口答了话、也说清了这首歌不放，那才真是没有。
      expect(looksLikeThrottle('腾讯没返回播放链接（-400515）'), isFalse);
    });

    test('播放器那句 Source error 要翻成人话', () {
      // 地址取到了却打不开（过期 / 403 / 半截文件）时，ExoPlayer 只给这一句，
      // 括号里那个错误码对她没有任何意义。
      final s = humanizeError(Exception('(0) Source error'));
      expect(s, contains('地址'));
      expect(s, contains('重试'));
      expect(looksLikeVipWall(s), isFalse); // 翻出来的话不能顺带把歌判成会员墙
    });
  });
}
