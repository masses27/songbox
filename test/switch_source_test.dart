import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/ui/pages/builtin_library.dart';

Song _s(String name, String singer,
        {String source = 'kw', String mid = 'x', int? sec, int fee = 0}) =>
    Song(source: source, songmid: mid, name: name, singer: singer, interval: sec, fee: fee);

void main() {
  group('pickTwin', () {
    final want = _s('晴天', '周杰伦', source: 'wy', sec: 269);

    test('takes the same title and singer', () {
      final hit = BuiltinLibrary.pickTwin([_s('搁浅', '周杰伦', sec: 263), _s('晴天', '周杰伦', sec: 271)], want);
      expect(hit?.name, '晴天');
    });

    test('accepts punctuation and case noise', () {
      final hit = BuiltinLibrary.pickTwin([_s(' 晴天 (Live) ', 'Jay Chou 周杰伦', sec: 269)], want);
      expect(hit, isNotNull);
    });

    test('rejects a different singer', () {
      expect(BuiltinLibrary.pickTwin([_s('晴天', '李荣浩', sec: 260)], want), isNull);
    });

    test('rejects a version whose length is way off', () {
      // 现场版/remix 同名同歌手，但时长差出一截，放错了比放不出更莫名其妙。
      expect(BuiltinLibrary.pickTwin([_s('晴天', '周杰伦', sec: 420)], want), isNull);
    });

    test('rejects an unrelated list', () {
      final cands = [_s('稻香', '周杰伦', sec: 223), _s('夜曲', '周杰伦', sec: 226)];
      expect(BuiltinLibrary.pickTwin(cands, want), isNull);
    });

    test('survives an empty or missing title', () {
      expect(BuiltinLibrary.pickTwin([_s('', '周杰伦')], _s('', '周杰伦', source: 'wy')), isNull);
    });
  });

  group('会员墙标记', () {
    test('只有网易云的 fee=1 算挡在会员后面', () {
      expect(Song(source: 'wy', songmid: 'a', name: 'x', fee: 1).needsVip, isTrue);
      expect(Song(source: 'wy', songmid: 'a', name: 'x', fee: 8).needsVip, isFalse);
      // 酷我没有这个字段，别把 0/1 当版权标记乱标。
      expect(Song(source: 'kw', songmid: 'a', name: 'x', fee: 1).needsVip, isFalse);
    });

    test('收藏、歌单存成 JSON 再读回来，标记不会丢', () {
      final raw = jsonDecode(jsonEncode(Song(source: 'wy', songmid: 'a', name: 'x', fee: 1).toJson()));
      expect(Song.fromJson(Map<String, dynamic>.from(raw)).needsVip, isTrue);
    });

    test('QQ 的 fee=1 也算挡在墙后：角标、整单体检、7 天标记都按这一条', () {
      // `needsVip` 说的是「网易云端内放不出来」，那句实测只对 wy 成立；
      // 而「这首得靠换源才出得来声音」wy 和 tx 都一样。按前者判的话，QQ 那批
      // 会员歌不标角标、不进整单体检，还每 12 小时重撞一次十八秒的换源链子。
      final txVip = Song(source: 'tx', songmid: 'a', name: 'x', fee: 1);
      expect(txVip.twinBlocked, isTrue);
      expect(txVip.needsVip, isFalse);
      // 酷我的付费标记不可靠，B 站匿名本来就出整首：都别乱标。
      expect(Song(source: 'kw', songmid: 'a', name: 'x', fee: 1).twinBlocked, isFalse);
      expect(Song(source: 'bl', songmid: 'BV1', name: 'x', fee: 1).twinBlocked, isFalse);
    });

    test('酷狗用 Privilege 折算成同一个 fee=1，也算挡在墙后', () {
      // 0.8.26 接酷狗匿名整首时最容易漏的一刀：它的搜索直接写 fee，
      // 而「候选本身要会员就别当换源目标」那道关（pickTwins）认的是 twinBlocked。
      // 漏了 kg，付费的酷狗候选会挤掉免费的那条，还会在墙前多跑一次取链。
      final kgVip = Song(source: 'kg', songmid: 'H1', name: 'x', fee: 1);
      expect(kgVip.twinBlocked, isTrue);
      // 端内直连那句「VIP 专属」只属于网易云，酷狗的要留着自己的归因。
      expect(kgVip.needsVip, isFalse);
      expect(Song(source: 'kg', songmid: 'H2', name: 'x', fee: 0).twinBlocked, isFalse);
    });
  });

  group('找其他版本', () {
    final want = _s('江南', '林俊杰', source: 'wy', mid: 'self', sec: 273, fee: 1);

    test('自动换源只认同一条录音，时长差一截的现场版会被筛掉', () {
      final cands = [
        _s('江南', '林俊杰', source: 'wy', mid: 'a', sec: 275),
        _s('江南 (Live)', '林俊杰', source: 'wy', mid: 'b', sec: 340),
      ];
      expect(BuiltinLibrary.pickTwins(cands, want, max: 2).map((e) => e.songmid).toList(), ['a']);
    });

    test('「找其他版本」放宽到现场版、翻唱，但同一录音仍排在最前', () {
      final cands = [
        _s('江南 (Live)', '林俊杰', source: 'wy', mid: 'b', sec: 340),
        _s('江南', '林俊杰', source: 'wy', mid: 'a', sec: 275),
        _s('不为而作', '林俊杰', source: 'wy', mid: 'c', sec: 260),
      ];
      final out = BuiltinLibrary.pickTwins(cands, want, max: 9, loose: true).map((e) => e.songmid).toList();
      expect(out, ['a', 'b']); // 歌名都对不上的那条不会混进来
    });

    test('会员墙后面的歌不能当换源目标，但要出现在其他版本列表里', () {
      final vip = _s('江南', '林俊杰', source: 'wy', mid: 'd', sec: 272, fee: 1);
      expect(BuiltinLibrary.pickTwins([vip], want), isEmpty);
      expect(BuiltinLibrary.pickTwins([vip], want, loose: true).map((e) => e.songmid).toList(), ['d']);
    });

    test('不会把这首歌自己当成它的另一个版本', () {
      expect(BuiltinLibrary.pickTwins([want], want, loose: true), isEmpty);
    });
  });

  group('自动换源不放分支版本', () {
    final want = _s('当你', '林俊杰', source: 'wy', mid: 'self', sec: 265, fee: 1);

    /// 这些是实测里被当成「同一首歌」混进换源结果的 QQ 候选。
    Song? pick(String name, {String singer = '林俊杰', int sec = 265}) => BuiltinLibrary
        .pickTwin([_s(name, singer, source: 'tx', mid: 't', sec: sec)], want);

    test('纯音乐、降调、DJ、独唱一律否掉', () {
      for (final bad in [
        '当你 (纯音乐)',
        '当你 (降调版本)',
        '当你 (DJ KrixLee版)',
        '当你 (独唱)',
        '当你 remix',
        '当你 (伴奏)',
      ]) {
        expect(pick(bad), isNull, reason: bad);
      }
    });

    test('括号里是别人的名字 = 翻唱，否掉', () {
      expect(pick('当你 (熊先生)'), isNull);
      // 歌手字段本身就写着翻唱人，原来的歌手关也会挡住
      expect(pick('当你 (熊先生)', singer: '熊先生'), isNull);
    });

    test('垃圾上传的花名否掉', () {
      expect(pick('《当你》------林俊杰冷门但好听歌曲系列。。。'), isNull);
    });

    test('现场版排在原版后面，没有原版时还能顶上', () {
      final studio = _s('当你', '林俊杰', source: 'tx', mid: 'a', sec: 265);
      final live = _s('当你 (Live)', '林俊杰', source: 'tx', mid: 'b', sec: 270);
      expect(BuiltinLibrary.pickTwins([live, studio], want, max: 1).first.songmid, 'a');
      expect(BuiltinLibrary.pickTwin([live], want)?.songmid, 'b');
    });

    test('年份括号不算分支版本', () {
      expect(pick('当你 (2013)'), isNotNull);
    });

    test('「找其他版本」还是能看到这些，只是排在原版后面', () {
      final cands = [
        _s('当你 (纯音乐)', '林俊杰', source: 'tx', mid: 'inst', sec: 265),
        _s('当你 (Live)', '林俊杰', source: 'tx', mid: 'live', sec: 270),
        _s('当你', '林俊杰', source: 'tx', mid: 'a', sec: 265),
      ];
      final out = BuiltinLibrary.pickTwins(cands, want, max: 9, loose: true).map((e) => e.songmid).toList();
      expect(out, ['a', 'live', 'inst']);
    });
  });

  group('换源候选值得问哪几档', () {
    // 档位是**候选那批平台**的能力，不是原曲的设置。会员墙那一步把 128k 从原曲的
    // 阶梯里砍掉了（网易云三档一起挡，多问一遍只是白等），照这张砍过的表去问只有
    // 128k 的那类脚本，永远问不到它们唯一有的那一档，还要顺手打一周的「没有免费版」。
    test('要的和最便宜的一档，最多两次', () {
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'kw'), 'flac'),
          ['flac', '128k']);
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'kw'), '320k'),
          ['320k', '128k']);
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'wy'), '128k'), ['128k']);
    });

    test('B 站匿名整首只有 192k，问第二遍是把同一条接口再打一次', () {
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'bl'), 'flac'), ['192k']);
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'bl'), '128k'), ['192k']);
    });

    test('酷狗匿名整首只有 128k，同理只问一次', () {
      // 搜索回的那个哈希就是 128k 那一份文件：按设置里的无损去问，
      // 多出来的那一次只是整单体检里多撞一遍酷狗的频率限制。
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'kg'), 'flac'), ['128k']);
      expect(BuiltinLibrary.twinLadder(_s('晴天', '周杰伦', source: 'kg'), '320k'), ['128k']);
    });
  });

  group('撞墙那句话点名的兜底名单', () {
    // 提示条上只有这一句是她能看见的：照着它决定要不要开会员、要不要换版本，
    // 所以名单里既不能漏掉新接进来的那家，也不能把撞墙的本家自己算成一条路。
    test('网易云、QQ 撞墙时说清还剩谁会兜整首', () {
      expect(
          BuiltinLibrary.wallMessage(_s('晴天', '周杰伦', source: 'wy', fee: 1), what: '同一首'),
          '网易云这首要会员，B 站、酷狗和别的源上也没找到同一首');
      expect(BuiltinLibrary.wallMessage(_s('晴天', '周杰伦', source: 'tx', fee: 1), what: '同一首'),
          'QQ这首要会员，B 站、酷狗和别的源上也没找到同一首');
    });

    test('直接点酷狗那一首撞墙时，不能把自己列进兜底名单', () {
      // 她从「找其他版本」里挑了带角标的酷狗条目，队列里这一首的 source 就是 kg。
      // 照原来那句硬写，会变成「酷狗这首要会员，B 站、酷狗和别的源上也没找到」——
      // 读起来像还有第二条酷狗的路，而那条候选本来就是它自己。
      final msg =
          BuiltinLibrary.wallMessage(_s('晴天', '周杰伦', source: 'kg', fee: 1), what: '同一首');
      expect(msg, '酷狗这首要会员，B 站和别的源上也没找到同一首');
      expect(RegExp('酷狗').allMatches(msg).length, 1);
    });
  });

  group('「这首放不出」的标记值不值得落盘', () {
    // 标记一打就是半天（会员歌一周），期间播放器直接跳过、补测也不再问。
    // 打错了的代价是「网络好了歌还是放不出」，所以这两条门槛钉死。
    final deadline = DateTime(2026, 10, 21, 12);

    test('接口都答了话、链子也跑完了，才算真的没有', () {
      expect(BuiltinLibrary.deadWarranted(false, DateTime(2026, 10, 21, 11, 59), deadline), isTrue);
    });

    test('断网或风控那一次不算 —— 网络一回来还得能再试', () {
      expect(BuiltinLibrary.deadWarranted(true, DateTime(2026, 10, 21, 11, 59), deadline), isFalse);
    });

    test('时间预算用到头也不算：那时候还有候选没试过', () {
      expect(
        BuiltinLibrary.deadWarranted(false, deadline.add(const Duration(milliseconds: 1)), deadline),
        isFalse,
      );
      expect(BuiltinLibrary.deadWarranted(false, deadline, deadline), isFalse);
    });
  });
}
