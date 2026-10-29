import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/library/library_store.dart';
import 'package:lyric_music/models/song.dart';
import 'package:lyric_music/player/player_service.dart';
import 'package:lyric_music/ui/pages/builtin_library.dart';

// 「整单收进收藏」这一轮新加的三段纯逻辑：一次收一批、定时时长怎么开口、
// 找其他版本时「没答话」和「真没有」怎么分开。
void main() {
  final a = Song(source: 'wy', songmid: 'a', name: '晴天');
  final b = Song(source: 'wy', songmid: 'b', name: '稻香');
  final c = Song(source: 'kg', songmid: 'a', name: '晴天（酷狗）');

  group('整单收进收藏挑出要新增的那一批', () {
    test('已经在收藏里的不算新增', () {
      // 报大了就是骗人：那一单里二十首本来就在，界面上不能写「已收进 50 首」。
      expect(LibraryStore.notYetFavorite([a], [a, b]).map((e) => e.songmid), ['b']);
    });

    test('同一批里自己撞车的只收一次', () {
      expect(LibraryStore.notYetFavorite(const [], [b, b, a]).length, 2,
          reason: '重复插进去，撤销就要按次数点');
    });

    test('同一个 mid 不同来源是两首歌，都得收', () {
      expect(LibraryStore.notYetFavorite([a], [c]).length, 1);
    });

    test('全收过时交出空列表，界面那句「本来就都在收藏里了」靠它', () {
      expect(LibraryStore.notYetFavorite([a, b], [a, b]), isEmpty);
    });

    test('顺序照着给进来的那份，不会把歌单倒过来收', () {
      expect(LibraryStore.notYetFavorite(const [], [b, a]).map((e) => e.songmid), ['b', 'a']);
    });
  });

  group('定时关闭的时长怎么说', () {
    test('不到一钟头还是分钟', () {
      expect(PlayerService.sleepLengthLabel(const Duration(minutes: 15)), '15 分钟');
      expect(PlayerService.sleepLengthLabel(const Duration(minutes: 45)), '45 分钟');
    });

    test('整小时不写成 90/120 分钟', () {
      expect(PlayerService.sleepLengthLabel(const Duration(minutes: 120)), '2 小时');
    });

    test('带零头的小时把两截都写出来', () {
      expect(PlayerService.sleepLengthLabel(const Duration(minutes: 90)), '1 小时 30 分钟');
    });
  });

  group('找其他版本：没答话和真没有分得开', () {
    test('四家全没答话时报的是「都没吭声」，不是「没找到别的版本」', () {
      final t = TwinSearch(songs: const [], failed: const ['wy', 'tx', 'bl', 'kg'], asked: 4);
      expect(t.allSilent, isTrue);
      expect(t.incomplete, isTrue);
    });

    test('有一家答了话就不能说全体沉默', () {
      final t = TwinSearch(songs: const [], failed: const ['bl', 'kg'], asked: 4);
      expect(t.allSilent, isFalse);
      // 屏上仍然一条都没有，而那两家确实没跑成 —— 这一格要留着「再搜一遍」。
      expect(t.incomplete, isTrue);
    });

    test('搜到了歌时 incomplete 让位给那批结果', () {
      final t = TwinSearch(songs: [a], failed: const ['kg'], asked: 4);
      expect(t.incomplete, isFalse);
      expect(t.allSilent, isFalse);
    });

    test('四家都答了话、只是真没有：两句责人都不能提网络', () {
      final t = TwinSearch(songs: const [], failed: const [], asked: 4);
      expect(t.incomplete, isFalse);
      expect(t.allSilent, isFalse);
    });
  });
}
