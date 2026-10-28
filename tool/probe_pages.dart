// ignore_for_file: avoid_print
// Probe: does /api/playlist/list actually paginate for a category?
// The discover page wants a 「换一批」 on non-推荐 categories, which only makes
// sense if offset moves and the returned ids differ.
import 'package:lyric_music/music_sdk/wy_native.dart';

Future<List<String>> page(String cat, int limit, int offset) async {
  final b = await WyNative.getJson('/api/playlist/list',
      query: {'cat': cat, 'order': 'hot', 'limit': '$limit', 'offset': '$offset'});
  final list = (b['playlists'] as List?) ?? const [];
  print('  cat=$cat offset=$offset code=${b['code']} n=${list.length} '
      'keys=${b.keys.toList()} more=${b['more']} total=${b['total']}');
  return list.whereType<Map>().map((e) {
    final n = (e['name'] ?? '').toString();
    return '${e['id']}|${n.length > 12 ? n.substring(0, 12) : n}';
  }).toList();
}

Future<void> main() async {
  for (final cat in ['华语', '睡眠']) {
    final a = await page(cat, 12, 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final b = await page(cat, 12, 12);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final c = await page(cat, 12, 24);
    final overlap = a.toSet().intersection(b.toSet());
    print('$cat 第1页vs第2页 重合=$overlap / ${a.length}');
    print('  第1页首3=${a.take(3).toList()}');
    print('  第2页首3=${b.take(3).toList()}');
    print('  第3页首3=${c.take(3).toList()}');
    print('  第1页与第3页重合=${a.toSet().intersection(c.toSet()).length}');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  // 「推荐」那条个性化接口挪 offset 之外，看它给不给总数
  final r = await WyNative.weapi({'limit': 12, 'offset': 0, 'total': true, 'n': 1000, 'type': 0},
      '/weapi/personalized/playlist');
  print('personalized keys=${r.keys.toList()} hasMore=${r['hasMore']} size=${(r['result'] as List?)?.length}');
}
