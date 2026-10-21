import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/util/fuzzy_query.dart';

/// 「搜不到」有一半其实是输入本身的问题：全角空格看不见、输入法自动补的空格、
/// 名字里手滑多打的一个字。这一层全在本地，不用问任何服务器。
void main() {
  group('发出去之前把关键词收拾干净', () {
    test('全角字母数字换成半角', () {
      expect(normalizeKeyword('ＡＢＣ１２３'), 'ABC123');
    });

    test('全角空格和连着打的空格都压成一个', () {
      expect(normalizeKeyword('晴天\u{3000}周杰伦'), '晴天 周杰伦');
      expect(normalizeKeyword('  晴天   周杰伦  '), '晴天 周杰伦');
      expect(normalizeKeyword('晴天\n周杰伦'), '晴天 周杰伦');
    });

    test('输入法塞的零宽空格直接抹掉', () {
      expect(normalizeKeyword('晴\u{200B}天'), '晴天');
    });

    test('纯中文的歌名一个字都不动', () {
      expect(normalizeKeyword('晴天'), '晴天');
      expect(normalizeKeyword('周杰伦'), '周杰伦');
    });

    test('全角标点当成词与词之间的分隔', () {
      // 实测：晴天／周杰伦 207 条，晴天 周杰伦 250 条。那个斜杠在她手里就是分隔符。
      expect(normalizeKeyword('晴天／周杰伦'), '晴天 周杰伦');
      expect(normalizeKeyword('晴天、周杰伦'), '晴天 周杰伦');
      expect(normalizeKeyword('晴天（Live）'), '晴天 Live');
    });

    test('收拾完是空的就等于没输入', () {
      expect(normalizeKeyword('\u{3000} \u{200B} '), '');
    });
  });

  group('一个都没搜到时还能怎么问', () {
    test('手滑多打的空格：去掉空格再搜一遍', () {
      expect(relaxations('周杰 伦'), contains('周杰伦'));
    });

    test('两个词拆开各搜一遍，按她打的顺序', () {
      expect(relaxations('周杰伦 晴天'), ['周杰伦晴天', '周杰伦', '晴天']);
    });

    test('本来就只有一个词，且没多打空格，就别硬造备选', () {
      expect(relaxations('晴天'), isEmpty);
    });

    test('一个字的名不进备选，但合起来的写法还是给', () {
      expect(relaxations('阿 爱'), ['阿爱']);
    });

    test('备选里永远不再出现刚搜过的那个词', () {
      for (final kw in ['晴天', '晴天 周杰伦', ' 晴天 ']) {
        expect(relaxations(kw), isNot(contains(normalizeKeyword(kw))));
      }
    });

    test('备选最多四个，空态下面放不下更多', () {
      expect(relaxations('a bb cc dd ee ff gg').length, lessThanOrEqualTo(4));
    });
  });
}
