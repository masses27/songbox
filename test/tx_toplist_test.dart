import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/music_sdk/tx_search.dart';

/// 搜索域名挂了以后，「检测」改从音乐榜单拿对照曲（本机实测 `c.y.qq.com`/`c6.y.qq.com`
/// 在她手机上同时回 HTTP 500，而榜单和取链走的 `u.y.qq.com` 是通的）。
/// 榜单条目的字段名跟搜索接口不是一套，认错就会把会员歌当免费歌拿去试。
void main() {
  final hot = {
    'id': 4829554,
    'mid': '001bLkWD2EYA4P',
    'name': '天龙八部之宿敌',
    'singer': [
      {'id': 7221, 'mid': '000CK5xN3yZDJt', 'name': '许嵩'},
    ],
    'album': {'id': 81614, 'mid': '002JzRQD2zjvxG', 'name': '天龙八部之宿敌'},
    'interval': 264,
    'pay': {'pay_month': 1, 'pay_play': 1, 'pay_down': 1},
  };

  group('榜单条目读成 Song', () {
    test('名字在 name、付费标记写成 pay_play', () {
      final song = TxSearch.parseToplistSong(hot)!;
      expect(song.songmid, '001bLkWD2EYA4P');
      expect(song.name, '天龙八部之宿敌');
      expect(song.singer, '许嵩');
      expect(song.source, 'tx');
      expect(song.fee, 1);
      expect(song.pic, contains('002JzRQD2zjvxG'));
    });

    test('pay_play=0 才算能拿来匿名试', () {
      final free = TxSearch.parseToplistSong({...hot, 'pay': {'pay_play': 0}})!;
      expect(free.fee, 0);
      // 榜单偶尔不带 pay 这段：按「没被标付费」处理，让它去撞一次取链，
      // 总过一开始就没有候选。
      expect(TxSearch.parseToplistSong({...hot}..remove('pay'))!.fee, 0);
    });

    test('没有 mid 的条目丢掉，专辑缺失就不拼封面', () {
      expect(TxSearch.parseToplistSong({'name': '没有 mid'}), isNull);
      final noAlbum = TxSearch.parseToplistSong({...hot}..remove('album'))!;
      expect(noAlbum.pic, isNull);
      expect(noAlbum.albumName, isEmpty);
    });
  });

  group('对照曲先挑原版', () {
    Song named(String name) =>
        TxSearch.parseToplistSong({...hot, 'name': name, 'pay': {'pay_play': 0}})!;

    test('带括号的版本排到最后，其余保持原来的名次顺序', () {
      final picked = Song.preferOriginal([
        named('晴天（DJ沈念版）'),
        named('晴天'),
        named('晴天（邓紫棋）'),
        named('安静'),
      ]);
      expect(
        picked.map((s) => s.name),
        ['晴天', '安静', '晴天（DJ沈念版）', '晴天（邓紫棋）'],
      );
    });

    test('全是分支版本时也还有歌可试', () {
      final picked = Song.preferOriginal([named('晴天（Live）'), named('晴天（伴奏）')]);
      expect(picked.length, 2);
      expect(picked.first.name, '晴天（Live）');
    });
  });
}
