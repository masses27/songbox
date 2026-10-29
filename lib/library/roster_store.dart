import 'dart:io';

import '../models/results.dart';
import '../util/app_paths.dart';
import '../util/json_file.dart';
import '../util/roster.dart';

/// 名单多久之内不用再打接口。27 格一次不到一秒（实测 794ms / 910ms 两遍），但那是 27 次请求，
/// 开着应用来回进出名单页不该每次都去敲一遍；而这份是接口按热度给的一批人，
/// 攒太久就旧了。
const rosterFreshFor = Duration(days: 7);

/// 磁盘上那一份名单。
class RosterSnapshot {
  final Map<String, List<ArtistInfo>> buckets;
  final DateTime fetchedAt;
  RosterSnapshot(this.buckets, this.fetchedAt);

  int get artistCount => buckets.values.fold(0, (s, v) => s + v.length);

  /// 这一份还能不能用。[now] 只为单测留的口子。
  bool fresh({DateTime? now}) =>
      (now ?? DateTime.now()).difference(fetchedAt) < rosterFreshFor;

  /// 哪些格还缺着。拉回来的格子少于全部格子就有条要交代。
  List<String> get missingLetters => missingBuckets(buckets);
}

/// 名单落盘。
///
/// 存这一份不是为了离线也能看名单（离线时那份数据本身就是旧的），是为了
/// 「点进来先有东西」：上一次拉全过的人，这次直接就是满屏 2700 位，
/// 一次接口都不用敲 —— 重打虽然只要不到一秒，也要让她对着一个转圈的圈。
/// 写盘走 [JsonFile]：先 `.tmp` 再 rename，中途掉电不会留下半截 JSON。
class RosterStore {
  RosterStore({this.dir});

  /// 测试注入的目录；真机留空，走 [AppPaths.sub]。
  final Directory? dir;

  File? _file;
  bool _dirFailed = false;

  Future<File?> _resolve() async {
    final cached = _file;
    if (cached != null) return cached;
    if (_dirFailed) return null;
    try {
      final d = dir ?? await AppPaths.sub('roster');
      final f = File('${d.path}/artists.json');
      _file = f;
      return f;
    } catch (e) {
      // 目录建不出来（存储正被回收）时不重试第二次，界面只需要知道「这次存不了」。
      _dirFailed = true;
      return null;
    }
  }

  /// 读盘。没有、读不出、格式不对都回 null —— 名单这种东西，旧不如无，
  /// 解错了会把一堆对不上号的歌手摆上屏。
  Future<RosterSnapshot?> load() async {
    final f = await _resolve();
    if (f == null) return null;
    final j = JsonFile.read(f, quarantine: false);
    if (j is! Map) return null;
    final letters = j['letters'];
    if (letters is! Map) return null;
    final buckets = <String, List<ArtistInfo>>{};
    letters.forEach((key, value) {
      if (key is! String || value is! List) return;
      final artists = value
          .whereType<Map>()
          .map((e) => ArtistInfo.fromNetEase(Map<String, dynamic>.from(e)))
          .whereType<ArtistInfo>()
          .toList();
      if (artists.isNotEmpty) buckets[key] = artists;
    });
    if (buckets.isEmpty) return null;
    return RosterSnapshot(buckets, _time(j['fetchedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0));
  }

  /// 写盘。成功回 null，失败回一句原因，让界面上那句「这次没存住」有出处。
  Future<String?> save(Map<String, List<ArtistInfo>> buckets) async {
    final f = await _resolve();
    if (f == null) return '名单目录没打开';
    return JsonFile.write(f, {
      'fetchedAt': DateTime.now().toIso8601String(),
      'letters': {
        for (final e in buckets.entries)
          if (e.value.isNotEmpty) e.key: [for (final a in e.value) _encode(a)],
      },
    });
  }

  /// 存的就是 [ArtistInfo.fromNetEase] 认得的那几个键，读回来不用另写一套解法。
  ///
  /// 只存界面那一行真要用的四栏。`briefDesc` 不存：2026-10-29 探针从这条接口按 App
  /// 的路子取回 2700 位，一位简介都没带（`probe_roster6.out` 四格统计全是「有简介 0」），
  /// 存了也是 2700 个空串摊在盘上。
  static Map<String, dynamic> _encode(ArtistInfo a) => {
        'id': a.id,
        'name': a.name,
        'picUrl': a.pic ?? '',
        // fromNetEase 认的是列表，界面拼出来的是一串「A / B」，存的时候拆回去。
        'alias': a.alias.isEmpty ? const <String>[] : a.alias.split(' / '),
        'musicSize': a.musicSize,
        'albumSize': a.albumSize,
      };

  static DateTime? _time(dynamic raw) => raw is String ? DateTime.tryParse(raw) : null;
}
