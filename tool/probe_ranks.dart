// ignore_for_file: avoid_print
import 'package:lyric_music/music_sdk/wy_leaderboard.dart';

Future<void> main() async {
  final list = await WyLeaderboard().list;
  print('count=${list.length}');
  for (final r in list) {
    print('${r.id}\t${r.name}');
  }
}
