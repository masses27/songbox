import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/music_sdk/bl_source.dart';
import 'package:lyric_music/util/humanize.dart';

/// B 站这一层只用来在会员墙后面捞整首，标题全靠上传者自己写，
/// 所以「哪条才算同一首」这道关必须钉在测试里：放错了比放不出更让人莫名其妙。
/// 下面这些标题都是本机 2026-10-20 从 `search/type` 原样抄回来的。
void main() {
  Map v(String title, String dur, {String bvid = 'BV1BZbSzZEGT', String pic = '', Object pay = 0}) => {
        'bvid': bvid,
        'title': title,
        'duration': dur,
        'pic': pic,
        'is_pay': pay,
        'badgepay': pay == 1,
      };

  final realBatch = [
    v('【𝐇𝐢-𝐑𝐞𝐬无损音质】｜《晴天》- 周杰伦 -‘故事的小黄花’', '4:30', bvid: 'BV1A'),
    v('在百万豪装录音棚大声听周杰伦《晴天》【Hi-res】', '4:30', bvid: 'BV1B'),
    v('【私藏馆】周杰伦《晴天》经典现场！', '5:12', bvid: 'BV1C'),
    v('【单曲循环】《晴天》周杰伦「故事的小黄花」', '43:5', bvid: 'BV1D'),
    v('晴天_周杰伦ktv', '4:29', bvid: 'BV1E'),
    v('【4K60FPS】陈奕迅《晴天》', '4:30', bvid: 'BV1F'),
  ];

  group('B 站候选门槛', () {
    test('两条原版都收下，现场版挤不进名额', () {
      final picks = BlSource.pickVideos(realBatch, wantName: '晴天', wantSinger: '周杰伦', wantSec: 269);
      // BV1A、BV1B 分数并列（歌名写在《》里、时长都对得上），所以这里只看集合不看顺序。
      expect(picks.map((s) => s.songmid).toSet(), {'BV1A', 'BV1B'});
    });

    test('翻唱、伴奏、KTV、43 分钟合集、歌手不对的都进不来', () {
      final picks = BlSource.pickVideos(
        [
          ...realBatch,
          v('晴天 周杰伦（翻唱）', '4:30', bvid: 'BV1G'),
          v('晴天 钢琴版 周杰伦', '4:30', bvid: 'BV1H'),
          v('【伴奏】晴天 周杰伦', '4:30', bvid: 'BV1I'),
        ],
        wantName: '晴天',
        wantSinger: '周杰伦',
        wantSec: 269,
        max: 8,
      );
      final ids = picks.map((s) => s.songmid).toSet();
      // D 是 43 分钟的「单曲循环」合集，F 是陈奕迅——都不是这一首。
      expect(ids.intersection({'BV1D', 'BV1E', 'BV1F', 'BV1G', 'BV1H', 'BV1I'}), isEmpty, reason: '$ids');
    });

    test('曲名没写在标题里的不要', () {
      expect(BlSource.pickVideos([v('周杰伦经典合集', '4:30')], wantName: '晴天', wantSinger: '周杰伦'), isEmpty);
    });

    test('时长缺失不淘汰，写成 1:02:03 的一小时片子淘汰', () {
      expect(BlSource.pickVideos([v('《晴天》周杰伦', '')], wantName: '晴天', wantSinger: '周杰伦'), hasLength(1));
      expect(
        BlSource.pickVideos([v('《晴天》周杰伦', '1:02:03')], wantName: '晴天', wantSinger: '周杰伦', wantSec: 269),
        isEmpty,
      );
    });

    test('现场版和原版同时在场时，原版先交给播放', () {
      final picks = BlSource.pickVideos([realBatch[2], realBatch[1]],
          wantName: '晴天', wantSinger: '周杰伦', wantSec: 269);
      expect(picks.first.songmid, 'BV1B');
    });

    test('合唱只要对上其中一个歌手', () {
      final picks = BlSource.pickVideos([v('《珊瑚海》周杰伦 Lu', '4:25')],
          wantName: '珊瑚海', wantSinger: '周杰伦、梁心颐', wantSec: 265);
      expect(picks, hasLength(1));
    });

    test('网易云那边写成「晴天 (Live)」也认得出曲名', () {
      final picks = BlSource.pickVideos([v('周杰伦《晴天》', '4:30')],
          wantName: '晴天 (Live)', wantSinger: '周杰伦', wantSec: 269);
      expect(picks, hasLength(1));
    });

    test('B 站自己要付费的稿件不要', () {
      for (final pay in [1, 2]) {
        expect(
          BlSource.pickVideos([v('《晴天》周杰伦', '4:30', pay: pay)], wantName: '晴天', wantSinger: '周杰伦'),
          isEmpty,
          reason: 'is_pay=$pay 是会员稿，匿名取不到链',
        );
      }
    });

    test('bvid 缺失或对不上号的不要', () {
      expect(
        BlSource.pickVideos(
          [v('《晴天》周杰伦', '4:30', bvid: ''), v('《晴天》周杰伦', '4:30', bvid: 'av12345')],
          wantName: '晴天',
          wantSinger: '周杰伦',
        ),
        isEmpty,
      );
    });

    test('交回来的候选带着原来那一首的曲名歌手，封面补上协议头', () {
      final picks = BlSource.pickVideos(
        [v('在百万豪装录音棚大声听周杰伦《晴天》【Hi-res】', '4:30', pic: '//i0.hdslb.com/bfs/archive/1d.jpg')],
        wantName: '晴天',
        wantSinger: '周杰伦',
        wantSec: 269,
      );
      final s = picks.single;
      expect(s.name, '晴天'); // 列表上不该冒出「【Hi-res】…」这种标题
      expect(s.singer, '周杰伦');
      expect(s.source, 'bl');
      expect(s.albumName, 'B 站');
      expect(s.interval, 270);
      expect(s.pic, 'https://i0.hdslb.com/bfs/archive/1d.jpg');
    });

    test('高亮标签先摘掉，不然曲名比对不上', () {
      final picks = BlSource.pickVideos([v('《<em class="keyword">晴天</em>》<em class="keyword">周杰伦</em>', '4:30')],
          wantName: '晴天', wantSinger: '周杰伦', wantSec: 269);
      expect(picks, hasLength(1));
    });
  });

  group('B 站档位', () {
    test('直链尾巴上的音轨号就是实际音质', () {
      expect(BlSource.tierOfUrl('https://upos-sz-mirrorbd.bilivideo.com/x/928930934_nb3-1-30280.m4s?deadline=1'),
          '192k');
      expect(BlSource.tierOfUrl('...928930934_nb3-1-30232.m4s'), '132k');
      expect(BlSource.tierOfUrl('...928930934_nb3-1-30216.m4s'), '64k');
      expect(BlSource.tierOfUrl('https://x/y.mp3'), '未知档位');
    });
  });

  group('防盗链头看地址，不看歌曲对象', () {
    // 换源给的是 B 站的音轨，队列里那一首却仍然写着 source=wy。以前播放/预取/下载
    // 三处都按 `song.source == 'bl'` 决定带不带 Referer，于是会员墙后面靠 B 站兜的
    // 那整类歌（综艺现场、Live 版）漏掉 Referer，实测三成就 403。
    test('B 站的三条镜像和备用域名都要补头', () {
      expect(BlSource.headersFor('https://upos-sz-mirrorbd.bilivideo.com/x/a-1-30280.m4s?deadline=1'),
          isNotNull);
      expect(BlSource.headersFor('https://mcdn01b.bilivideo.cn/upgcxcode/a.m4s'), isNotNull);
      expect(BlSource.headersFor('https://proxy.bilibili.com/x/y.m4s'), isNotNull);
    });

    test('网易云和腾讯的地址原样交给播放器', () {
      expect(BlSource.headersFor('http://m10.music.126.net/20261021/abc.mp3?vuutv=x'), isNull);
      expect(BlSource.headersFor('https://ws.stream.qqmusic.qq.com/M50000abc.mp3'), isNull);
    });
  });

  group('被限流不等于「这首没有」', () {
    // 换源链子会把「确认没有免费版」落盘一周。整单体检一次发几十次 B 站搜索，
    // 撞上一次 412 就把那一串歌全判死，是她最难自己发现的那种坏。
    test('B 站 412、腾讯 104009 都归成不稳定失败', () {
      expect(looksLikeThrottle(Exception('B 站搜索 把这次请求当成爬虫拦下了（HTTP 412），过一会儿再试')), isTrue);
      expect(looksLikeThrottle(Exception('B 站搜索 回 code -412：风控')), isTrue);
      expect(looksLikeThrottle(Exception('腾讯把这次请求判成无效了（104009，多半是问得太频繁）')), isTrue);
    });

    test('「这条视频没给音轨」这种实话不算限流', () {
      expect(looksLikeThrottle(Exception('B 站这条视频没给音轨（多半是会员专属稿）')), isFalse);
    });
  });

  group('会员墙的话术都要认出来', () {
    // 认出来的那一句决定界面上给不给「换版本」：重试对会员墙是白试。
    // 三个源各写各的（网易云两条、腾讯一条、换源链子一条），漏一种就少给一次机会。
    test('网易云、腾讯、链子收尾的说法都算会员墙', () {
      expect(looksLikeVipWall('这首是网易云会员专享，B 站和别的源上也没找到同一首'), isTrue);
      expect(looksLikeVipWall('VIP 专属：网易云这首要会员'), isTrue);
      expect(looksLikeVipWall('这首歌是网易云 VIP 专属'), isTrue);
      expect(looksLikeVipWall('腾讯这首也要会员'), isTrue);
      // 原曲不是网易云的会员歌时说的是这句（那句「网易云专享」是候选带进来的，别赖到网易云头上）
      expect(looksLikeVipWall('这首几个源上都要会员，没找到能播的免费版'), isTrue);
    });

    test('连不上、只有试听片段这些不是会员墙', () {
      expect(looksLikeVipWall('网络连接不通，确认手机能上网后重试'), isFalse);
      expect(looksLikeVipWall('酷我这首只有 11 秒试听'), isFalse);
      expect(looksLikeVipWall(null), isFalse);
    });
  });
}
