import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/music_sdk/kg_native.dart';
import 'package:lyric_music/util/humanize.dart';

/// 一条直链回执，只填这次要用的那几个字段。
KgReply _r({int http = 200, int? status, String error = '', String? url}) => (
      http: http,
      code: null,
      status: status,
      error: error,
      ssaCode: null,
      url: url,
      bitRate: null,
      fileSize: null,
      ext: '',
      raw: '',
    );

/// 归因那句话。拿不到地址时 `urlOrExplain` 是抛异常，测的就是抛出来的这句人话——
/// 播放器把它原样显示，`looksLikeVipWall` / `looksLikeThrottle` 也按它分类。
String _msg(KgReply reply) {
  try {
    return KgNative.urlOrExplain(reply);
  } on Exception catch (e) {
    return '$e'.replaceFirst('Exception: ', '');
  }
}

void main() {
  group('酷狗匿名直链的取链地址', () {
    // 电脑实测：哈希全大写、全小写都回 status:1，**大小写混着用只回 status:0 Bad key**。
    // 所以 key 必须签在真正送出去的那一串上。搜索给的哈希本来是大写，
    // 但收藏/歌单里存过一遍的、别处传进来的都说不准，规范化一次比到处小心便宜。
    const hash = 'F3A05B0D7E4A21D9B0C6E2F4A7D89012';

    test('哈希统一成大写后同时用在 hash 和 key 上', () {
      final uri = Uri.parse(KgNative.directApiUrl(hash));
      final sent = uri.queryParameters['hash']!;
      expect(sent, hash);
      expect(uri.queryParameters['key'], c.md5.convert(utf8.encode('${sent}kgcloudv2')).toString());
    });

    test('传进来的哈希是小写，签的也是同一串大写', () {
      final lower = KgNative.directApiUrl(hash.toLowerCase());
      expect(lower, KgNative.directApiUrl(hash));
      // 反过来钉一次：签在小写串上、发大写哈希，服务器只回 Bad key。
      final wrong = c.md5.convert(utf8.encode('${hash.toLowerCase()}kgcloudv2')).toString();
      expect(Uri.parse(lower).queryParameters['key'], isNot(wrong));
    });

    test('这条不要注册、不要 cookie、不要行为验证参数', () {
      final uri = Uri.parse(KgNative.directApiUrl(hash));
      expect(uri.host, 'trackercdn.kugou.com');
      for (final p in ['signature', 'dfid', 'mid', 'token']) {
        expect(uri.queryParameters.containsKey(p), isFalse, reason: '$p 不该出现在匿名直链里');
      }
    });
  });

  group('酷狗直链失败的归因', () {
    test('给了地址就是成功，不去读 status', () {
      expect(_msg(_r(status: 1, url: 'https://fsandroid.tx.kugou.com/a.mp3')),
          'https://fsandroid.tx.kugou.com/a.mp3');
    });

    test('status:2 说成「也要会员」，界面上就该给换版本', () {
      final msg = _msg(_r(status: 2));
      expect(msg, contains('要会员'));
      // 认得出这句，提示条上才带「换版本」按钮；它不是限流，别算成「过会儿再试」。
      expect(looksLikeVipWall(Exception(msg)), isTrue);
      expect(looksLikeThrottle(Exception(msg)), isFalse);
    });

    test('答的不是那个 JSON 要说成「返回异常」，否则一次拦截就打成七天没有免费版', () {
      // 换源链子按 looksLikeThrottle 决定这次算不算 flaky：算，就不落「这首确实放不出」
      // 的标记；不算，网络一恢复这首歌还要被跳过整整一周。
      final msg = _msg(_r(http: 200));
      expect(msg, contains('返回异常'));
      expect(looksLikeThrottle(Exception(msg)), isTrue);
      expect(looksLikeVipWall(Exception(msg)), isFalse);
    });

    test('status:0 把服务器原话带出来（Bad key 就是我们签错了串）', () {
      expect(_msg(_r(status: 0, error: 'Bad key')), contains('Bad key'));
      // 原话是空的也不能含糊成「没给地址」：那听上去像这首歌的问题。
      expect(_msg(_r(status: 0)), contains('key'));
    });

    test('status:1 却没给地址，说的是地址这一层，不是会员', () {
      final msg = _msg(_r(status: 1));
      expect(msg, contains('没给地址'));
      expect(looksLikeVipWall(Exception(msg)), isFalse);
    });
  });

  group('酷狗搜索结果的付费标记', () {
    // 实测抽样九条：Privilege 0/8 的匿名直链给整首，10 的一律 status:2。
    // PayMask 在这套查询参数下根本不回（以前解析出来永远是 0），所以判据只能是它。
    test('Privilege>=10 才算要会员', () {
      for (final free in [0, 8]) {
        expect(KgNative.isPaid(free), isFalse, reason: 'Privilege=$free 匿名能给整首');
      }
      for (final paid in [10, 11]) {
        expect(KgNative.isPaid(paid), isTrue, reason: 'Privilege=$paid 直链回 status:2');
      }
    });
  });
}
