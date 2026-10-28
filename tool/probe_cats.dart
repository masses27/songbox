// ignore_for_file: avoid_print
// Probe: which category names actually return playlists from /api/playlist/list.
// The catlist endpoints are 404 for anonymous calls, so the vocabulary has to ship
// with the app — and it should only ship the words that answer.
import 'package:lyric_music/music_sdk/wy_native.dart';

const groups = <String, List<String>>{
  '语种': ['华语', '欧美', '日语', '韩语', '粤语', '小语种', '法语', '德语', '意大利语', '西班牙语', '俄语', '泰语'],
  '风格': ['流行', '摇滚', '电子', '民谣', '古风', '说唱', 'R&B', '轻音乐', '爵士', '古典', '金属', '蓝调', '后摇', '唱作', '翻唱'],
  '场景': ['工作', '学习', '睡眠', '开车', '运动', '旅行', '深夜', '聚会', '游戏', '动漫', '影视原声', 'KTV', '儿童'],
  '情感': ['怀旧', '伤感', '治愈', '放松', '兴奋', '孤独', '清新', '浪漫'],
  '主题': ['励志', '网络热歌', '校园', '男声', '女声', '吉他', '钢琴', '纯音乐', '儿歌'],
};

Future<void> main() async {
  for (final g in groups.entries) {
    final ok = <String>[];
    final bad = <String>[];
    for (final cat in g.value) {
      try {
        final b = await WyNative.getJson('/api/playlist/list',
            query: {'cat': cat, 'order': 'hot', 'limit': '5', 'offset': '0'});
        final list = b['playlists'];
        final n = list is List ? list.length : 0;
        (n >= 3 ? ok : bad).add('$cat($n)');
      } catch (e) {
        bad.add('$cat(throw ${e.toString().substring(0, 40)})');
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    print('${g.key} 有货=${ok.join(' ')} || 没货=${bad.join(' ')}');
  }
}
