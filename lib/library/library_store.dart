import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/results.dart';
import '../models/song.dart';
import '../util/app_paths.dart';
import '../util/json_file.dart';
import 'taste_profile.dart';
import 'user_playlist.dart';

enum LibraryKind { favorites, recent, downloaded }

/// 一首歌被听出来的样子：最后一次什么时候开播、总共开播几次、完整听完几次、
/// 最后一次听到第几秒。口味引擎用的就是这四个数 ——「点开就划走」和「听完一整首」
/// 差着一个量级，可原来的最近播放把这两件事记成了同一种。
///
/// 顺手也存歌名里那位歌手和时长：最近播放只留 200 条，她半年前反复听完过的那个人
/// 早被挤出去了，光靠那四个数就再也说不出「这些计数属于谁」。
class PlayStat {
  int at;
  int plays;
  int done;
  int heard;
  String singer;
  int interval;

  PlayStat(
      {this.at = 0,
      this.plays = 0,
      this.done = 0,
      this.heard = 0,
      this.singer = '',
      this.interval = 0});

  factory PlayStat.fromJson(Map<String, dynamic> j) => PlayStat(
        at: (j['at'] as num?)?.toInt() ?? 0,
        plays: (j['plays'] as num?)?.toInt() ?? 0,
        done: (j['done'] as num?)?.toInt() ?? 0,
        heard: (j['heard'] as num?)?.toInt() ?? 0,
        singer: j['singer'] as String? ?? '',
        interval: (j['interval'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'at': at,
        'plays': plays,
        'done': done,
        'heard': heard,
        if (singer.isNotEmpty) 'singer': singer,
        if (interval > 0) 'interval': interval,
      };
}

/// Lightweight JSON-file-backed library for favorites / recent plays / downloads.
/// Keeps this project dependency-free (no sqflite schema churn) while
/// remaining safe against process restarts.
class LibraryStore extends ChangeNotifier {
  static final LibraryStore instance = LibraryStore._();
  LibraryStore._();

  late final Directory _root;
  final Map<LibraryKind, List<Song>> _by = {
    LibraryKind.favorites: [],
    LibraryKind.recent: [],
    LibraryKind.downloaded: [],
  };
  final Map<LibraryKind, bool> _dirty = {
    LibraryKind.favorites: false,
    LibraryKind.downloaded: false,
    LibraryKind.recent: false,
  };

  /// `source:songmid` -> absolute path of the file this app downloaded, so
  /// playback can skip the network entirely.
  final Map<String, String> _localPaths = {};

  /// 自建歌单, persisted as one small JSON file.
  final List<UserPlaylist> _playlists = [];
  Timer? _autosave;
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _root = await AppPaths.sub('library');
    if (!_root.existsSync()) _root.createSync(recursive: true);
    for (final kind in LibraryKind.values) {
      final data = JsonFile.read(_file(kind));
      if (data is List) {
        _by[kind] = data.map((e) => Song.fromJson(Map<String, dynamic>.from(e))).toList();
      }
    }
    final j = JsonFile.read(_pathsFile);
    if (j is Map) {
      j.forEach((k, v) {
        if (k is String && v is String) _localPaths[k] = v;
      });
    }
    final pj = JsonFile.read(_playlistsFile);
    if (pj is List) {
      _playlists.addAll(pj.whereType<Map>().map((e) => UserPlaylist.fromJson(Map<String, dynamic>.from(e))));
    }
    final sj = JsonFile.read(_sheetsFile);
    if (sj is List) {
      _sheets.addAll(sj.whereType<Map>().map((e) => SheetInfo.fromJson(Map<String, dynamic>.from(e))));
    }
    _readVip(JsonFile.read(_vipFile));
    _readStats(JsonFile.read(_statsFile));
    _loaded = true;
    _favKeys = null;
    notifyListeners();
  }

  File _file(LibraryKind kind) => File('${_root.path}/${kind.name}.json');
  File get _pathsFile => File('${_root.path}/downloads_paths.json');
  File get _playlistsFile => File('${_root.path}/playlists.json');

  static String keyOf(Song s) => '${s.source}:${s.songmid}';

  /// Path of the already-downloaded file for this song, or null when the song
  /// is not on the device (or the file was deleted by the user).
  String? localFile(Song s) {
    final p = _localPaths[keyOf(s)];
    if (p == null) return null;
    return File(p).existsSync() ? p : null;
  }

  /// 列表每行都要问一次「下载过没有」，逐行 stat 磁盘会把构建拖慢，
  /// 所以这里缓存 30 秒的结果。真正要拿路径去播放时走 [localFile]。
  final Map<String, ({DateTime at, bool ok})> _exists = {};

  bool hasLocalFile(Song s) {
    final p = _localPaths[keyOf(s)];
    if (p == null) return false;
    final hit = _exists[p];
    if (hit != null && DateTime.now().difference(hit.at) < const Duration(seconds: 30)) return hit.ok;
    final ok = File(p).existsSync();
    _exists[p] = (at: DateTime.now(), ok: ok);
    return ok;
  }

  void recordLocalPath(Song s, String path) {
    _localPaths[keyOf(s)] = path;
    _exists.remove(path);
    _writePaths();
    _markDirty(LibraryKind.downloaded);
  }

  void _writePaths() => JsonFile.write(_pathsFile, _localPaths);


  List<Song> list(LibraryKind kind) => List.unmodifiable(_by[kind] ?? const []);

  /// 收藏集合每页几百行都在查，线性扫一遍列表会拖慢列表构建。
  Set<String>? _favKeys;

  bool isFavorite(Song s) =>
      (_favKeys ??= {for (final e in _by[LibraryKind.favorites]!) keyOf(e)}).contains(keyOf(s));

  void toggleFavorite(Song s) {
    final list = _by[LibraryKind.favorites]!;
    final idx = list.indexWhere((e) => e.source == s.source && e.songmid == s.songmid);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, s);
    }
    _markDirty(LibraryKind.favorites);
  }

  void recordRecent(Song s) {
    final list = _by[LibraryKind.recent]!;
    list.removeWhere((e) => e.source == s.source && e.songmid == s.songmid);
    list.insert(0, s);
    while (list.length > 200) {
      list.removeLast();
    }
    _markDirty(LibraryKind.recent);
    notePlay(s);
  }

  // ---- 听歌记账 ----------------------------------------------------------
  //
  // 「播了」和「听完了」是两件事，可原来的最近播放只记得前者：一首歌被划过去
  // 和被听完，在数据里长得一模一样。口味要的是这一首究竟听进去多少 —— 所以
  // 每首都记开播时间、播过几次、听完几次、最后听到第几秒；再按天存一份条数，
  // 好让「这周听了多少」不用回放到原始事件。
  //
  // 单独放一个文件：recent.json 的结构是 Song 列表，别为了几个计数去动那个模型。

  final Map<String, PlayStat> _stats = {};
  final Map<String, int> _days = {};

  File get _statsFile => File('${_root.path}/play_stats.json');

  /// 一首歌最多留一条记录，但记录本身比最近播放那 200 行长寿得多：口味引擎要看的
  /// 是半年前也反复播过的那个人，把统计跟着列表一起截掉，就把她听过的最好的部分丢了。
  static const _statsCap = 2000;
  static const _daysCap = 180;

  PlayStat? playStat(Song s) => _stats[keyOf(s)];

  /// 取这一首的计数条目，顺手把歌手名和时长填上：0.8.23 之前的老记录里没有这两项，
  /// 而正在放这首的这一刻是唯一还拿得到它们的时候。
  PlayStat _statOf(Song s) {
    final st = _stats.putIfAbsent(keyOf(s), PlayStat.new);
    if (st.singer.isEmpty && s.singer.isNotEmpty) st.singer = s.singer;
    final sec = s.interval ?? 0;
    if (st.interval <= 0 && sec > 0) st.interval = sec;
    return st;
  }

  /// 她本机听出来的口味。进「今日私荐」时算一次：几百条记录，纯内存加权，
  /// 不用等网络也不必落盘。
  Taste taste() => Taste.from(
        favorites: list(LibraryKind.favorites),
        recent: list(LibraryKind.recent),
        playlistSongs: [for (final p in _playlists) ...p.songs],
        stats: {
          for (final e in _stats.entries)
            e.key: (plays: e.value.plays, done: e.value.done, heard: e.value.heard, at: e.value.at),
        },
        // 计数比最近播放那 200 条活得久得多，被挤出去的那些靠这里把名字带回来。
        backfill: {
          for (final e in _stats.entries)
            if (e.value.singer.isNotEmpty) e.key: (singer: e.value.singer, interval: e.value.interval),
        },
      );

  /// 开播记账：一次「开始放这首」。
  void notePlay(Song s) {
    final now = DateTime.now();
    final st = _statOf(s)..at = now.millisecondsSinceEpoch;
    st.plays++;
    final day = _dayKey(now);
    _days[day] = (_days[day] ?? 0) + 1;
    if (_days.length > _daysCap) {
      final oldest = _days.keys.where((k) => k != day).toList()..sort();
      if (oldest.isNotEmpty) _days.remove(oldest.first);
    }
    if (_stats.length > _statsCap) _pruneStats();
    _dirtyStats = true;
    _scheduleStatsFlush();
  }

  /// 听到哪 / 有没有听完。[_stats] 里没这首歌（老数据或记账之前就在放）时补一条，
  /// 不然「听完过」这个最强的信号会被整批丢掉。
  void noteHeard(Song s, {required int heardSeconds, required bool completed}) {
    final st = _statOf(s);
    // 只往上抬：上次听到 200 秒、这次手滑点开 15 秒就收回，覆盖掉的话她在 180 秒
    // 处听完过这件事就没了，口味只会越算越不准。
    if (heardSeconds > st.heard) st.heard = heardSeconds;
    if (completed) st.done++;
    // 补记的条目也要有日期，不然半衰期会把它当常青信号算。
    if (st.at <= 0) st.at = DateTime.now().millisecondsSinceEpoch;
    _dirtyStats = true;
    _scheduleStatsFlush();
  }

  /// 按最后一次开播时间砍掉最旧的那些：口味只看最近的行为，过老的记录没价值。
  void _pruneStats() {
    final keys = _stats.keys.toList()..sort((a, b) => _stats[a]!.at.compareTo(_stats[b]!.at));
    for (var i = 0; i < keys.length - _statsCap && i < keys.length; i++) {
      _stats.remove(keys[i]);
    }
  }

  /// 某一天播了多少次。
  int playsOn(DateTime day) => _days[_dayKey(day)] ?? 0;

  /// 最近 [days] 天（含今天）一共播了多少次。天粒度直方图是这儿唯一能算的口径 ——
  /// 逐次事件不留在本地，一部手机听半年的量不该变成一份日志文件。
  int playsInLastDays(int days) {
    final today = DateTime.now();
    var sum = 0;
    for (var i = 0; i < days; i++) {
      sum += playsOn(today.subtract(Duration(days: i)));
    }
    return sum;
  }

  static String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 毫秒时间戳写成界面上读得通的「今天 / 昨天 / 3 天前 / 10 月 18 日」。
  static String dayLabel(int at) {
    if (at <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    final days = DateTime.now().difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days == 0) return '今天';
    if (days == 1) return '昨天';
    if (days < 7) return '$days 天前';
    return '${t.month} 月 ${t.day} 日';
  }

  Timer? _statsAutosave;
  bool _dirtyStats = false;

  void _scheduleStatsFlush() {
    _statsAutosave?.cancel();
    // 一次听歌只动一条记录，但连点十几首时不该每首都落一次盘。
    _statsAutosave = Timer(const Duration(seconds: 5), _flushStats);
  }

  void _flushStats() {
    if (!_dirtyStats) return;
    _dirtyStats = false;
    JsonFile.write(_statsFile, {
      'songs': _stats.map((k, v) => MapEntry(k, v.toJson())),
      'days': _days,
    });
  }

  void _readStats(Object? raw) {
    if (raw is! Map) return;
    final songs = raw['songs'];
    if (songs is Map) {
      songs.forEach((k, v) {
        if (k is! String || v is! Map) return;
        try {
          _stats[k] = PlayStat.fromJson(Map<String, dynamic>.from(v));
        } catch (_) {}
      });
    }
    final days = raw['days'];
    if (days is Map) {
      days.forEach((k, v) {
        if (k is String && v is num) _days[k] = v.toInt();
      });
    }
  }

  void markDownloaded(Song s) {
    final list = _by[LibraryKind.downloaded]!;
    list.removeWhere((e) => e.source == s.source && e.songmid == s.songmid);
    list.insert(0, s);
    _by[LibraryKind.downloaded] = list;
    _markDirty(LibraryKind.downloaded);
  }

  /// Swaps the whole downloaded list (used after a bulk delete) and forgets the
  /// local file mappings with it.
  void replaceDownloaded(List<Song> songs) {
    _by[LibraryKind.downloaded] = List.of(songs);
    _localPaths.clear();
    _writePaths();
    _markDirty(LibraryKind.downloaded);
  }

  /// 移出单首歌。返回它原来排在第几（不在列表里就是 -1），调用方拿这个位置做「撤销」。
  int remove(LibraryKind kind, Song s) {
    final list = _by[kind];
    if (list == null) return -1;
    final i = list.indexWhere((e) => e.source == s.source && e.songmid == s.songmid);
    if (i < 0) return -1;
    list.removeAt(i);
    if (kind == LibraryKind.downloaded) {
      // Forget the local copy so playback falls back to streaming; the file
      // itself is left alone (the user can clear it from 设置).
      if (_localPaths.remove(keyOf(s)) != null) _writePaths();
    }
    _markDirty(kind);
    return i;
  }

  /// 撤销一次「移出」：放回原来的位置。文件已经删掉的歌不该走这条路，所以只补记录。
  void putBack(LibraryKind kind, Song s, int index) {
    final list = _by[kind];
    if (list == null) return;
    if (list.any((e) => e.source == s.source && e.songmid == s.songmid)) return;
    list.insert(index.clamp(0, list.length), s);
    _markDirty(kind);
  }

  /// 整批清空，并把原内容返回给调用方做「撤销」。
  List<Song> clear(LibraryKind kind) {
    final old = List<Song>.of(_by[kind] ?? const []);
    if (old.isEmpty) return old;
    _by[kind] = <Song>[];
    _markDirty(kind);
    return old;
  }

  /// 撤销 [clear]：按原顺序整批放回去。
  void restore(LibraryKind kind, List<Song> songs) {
    if (songs.isEmpty) return;
    _by[kind] = List<Song>.of(songs);
    _markDirty(kind);
  }

  // ---- 自建歌单 -----------------------------------------------------------

  List<UserPlaylist> get playlists => List.unmodifiable(_playlists);

  UserPlaylist? playlist(String id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Which of the user's playlists already hold this song.
  List<UserPlaylist> playlistsOf(Song s) => _playlists.where((p) => p.has(s)).toList();

  UserPlaylist createPlaylist(String name) {
    final trimmed = name.trim().isEmpty ? '未命名歌单' : name.trim();
    final p = UserPlaylist(id: 'local-${DateTime.now().millisecondsSinceEpoch}', name: trimmed);
    _playlists.insert(0, p);
    _writePlaylists();
    return p;
  }

  void renamePlaylist(String id, String name) {
    final p = playlist(id);
    final trimmed = name.trim();
    if (p == null || trimmed.isEmpty || p.name == trimmed) return;
    p.name = trimmed;
    _writePlaylists();
  }

  void deletePlaylist(String id) {
    final before = _playlists.length;
    _playlists.removeWhere((p) => p.id == id);
    if (_playlists.length == before) return;
    _writePlaylists();
  }

  /// Returns true when the song was not in the playlist yet.
  bool addToPlaylist(String id, Song s) {
    final p = playlist(id);
    if (p == null) return false;
    final existing = p.songs.indexWhere((e) => e.source == s.source && e.songmid == s.songmid);
    if (existing >= 0) return false;
    p.songs.insert(0, s);
    _writePlaylists();
    return true;
  }

  /// 从自建歌单移出一首歌。返回它原来排在第几（不在里面就是 -1），
  /// 调用方拿这个位置做「撤销」。
  int removeFromPlaylist(String id, Song s) {
    final p = playlist(id);
    if (p == null) return -1;
    final i = p.songs.indexWhere((e) => e.source == s.source && e.songmid == s.songmid);
    if (i < 0) return -1;
    p.songs.removeAt(i);
    _writePlaylists();
    return i;
  }

  /// 撤销一次「移出歌单」：放回原来的位置。
  void putBackInPlaylist(String id, Song s, int index) {
    final p = playlist(id);
    if (p == null || index < 0) return;
    p.songs.insert(index.clamp(0, p.songs.length), s);
    _writePlaylists();
  }

  /// 自建歌单里拖动排序。
  void reorderPlaylist(String id, int oldIndex, int newIndex) {
    final p = playlist(id);
    if (p == null) return;
    final songs = p.songs;
    if (oldIndex < 0 || oldIndex >= songs.length) return;
    final moved = songs.removeAt(oldIndex);
    songs.insert(newIndex.clamp(0, songs.length), moved);
    _writePlaylists();
  }

  void _writePlaylists() {
    notifyListeners();
    JsonFile.write(_playlistsFile, _playlists.map((p) => p.toJson()).toList());
  }

  // ---- 一首歌一个源：放不出的歌记住能播的那个 ------------------------------
  //
  // 一首歌撞会员墙或整条链子跑空，要等十几二十秒。找到的替代版本落盘之后，
  // 下次 resolveUrl 第一步就命中；确认过放不出的也记一笔，短期内直接快速失败，
  // 不然 40 首的榜单每首都重跑一遍链子，跳到天黑。
  //
  // 不只会员歌：音源放不出的酷我单曲换到网易云同一首，也照这个记下来——
  // 「一首歌一个源」本来就是按曲库里的每一条分别记住用哪个。

  final Map<String, Song> _swaps = {};

  /// 键 -> 「这条判定过期之前的毫秒时间戳」。过期时间而不是标记时间，
  /// 因为会员歌和普通话不了的歌，值得重试验证的节奏不一样。
  final Map<String, int> _deadUntil = {};

  File get _vipFile => File('${_root.path}/vip_swaps.json');

  /// 已经替她找到的可播版本；没有就是 null。
  Song? swapSongFor(Song s) => _swaps[keyOf(s)];

  bool hasSwapSong(Song s) => _swaps.containsKey(keyOf(s));

  void rememberSwapSong(Song s, Song twin) {
    if (keyOf(s) == keyOf(twin)) return;
    _swaps[keyOf(s)] = twin;
    _deadUntil.remove(keyOf(s));
    _markVip();
  }

  /// 缓存的那条也可能失效（音源换了、下架了），忘掉它让下次重新找。
  void forgetSwapSong(Song s) {
    if (_swaps.remove(keyOf(s)) != null) _markVip();
  }

  /// 期限内确认过「找不到能播的版本」。到期就重新算，
  /// 因为音源和版权都会变，一条判定不该管一辈子。
  bool swapCheckedDead(Song s) {
    final until = _deadUntil[keyOf(s)];
    if (until == null) return false;
    if (until <= DateTime.now().millisecondsSinceEpoch) {
      _deadUntil.remove(keyOf(s));
      _markVip();
      return false;
    }
    return true;
  }

  /// 会员歌版权松动得慢，一周问一次就够；普通话不了的多半是音源那阵子抽风，
  /// 半天之后值得再试。
  static const _deadVip = Duration(days: 7);
  static const _deadOther = Duration(hours: 12);

  void markSwapDead(Song s) {
    // 判多久看的是「这条结论多久可能变」：会员墙后面找不到免费版是版权层面的事，
    // 一周内不会变；别的失败多半是当天的网络/风控，12 小时后再问。
    // 网易云和 QQ 的会员歌都算前者 —— 只认网易云的话，QQ 那批每 12 小时重撞一次
    // 十八秒的换源链子。
    final ttl = s.twinBlocked ? _deadVip : _deadOther;
    _deadUntil[keyOf(s)] = DateTime.now().add(ttl).millisecondsSinceEpoch;
    _swaps.remove(keyOf(s));
    _markVip();
  }

  /// 换音源之后调用：旧判定是在「那批取链能力」下得出的，不能继续拦着新歌。
  void clearSwapDead() {
    if (_deadUntil.isEmpty) return;
    _deadUntil.clear();
    _markVip();
  }

  /// 列表里还需要体检的歌：挡在会员墙后面、既没找到免费版也没确认过没有。
  /// 按 `twinBlocked` 算而不是只看网易云：QQ 的会员歌撞的也是同一堵墙，
  /// 漏掉它们等于那一批永远要等播到才现场跑换源。
  List<Song> vipNeedScan(Iterable<Song> songs) =>
      songs.where((s) => s.twinBlocked && !hasSwapSong(s) && !swapCheckedDead(s)).toList();

  int vipReadyCount(Iterable<Song> songs) => songs.where(hasSwapSong).length;

  Timer? _vipAutosave;
  bool _vipDirty = false;

  /// 这个文件存的是「整张换源表」，一次写入要把所有条目重新编码一遍。
  /// 而整单体检是几十首连着记：逐首同步落盘等于把同一张表重写几十遍，
  /// 全在主 isolate 上——她那边就是滚动时一顿卡。和收藏一样攒 2 秒写一次，
  /// 切后台时 [flushNow] 兜底。
  void _markVip() {
    _vipDirty = true;
    _vipAutosave?.cancel();
    _vipAutosave = Timer(const Duration(seconds: 2), _flushVip);
  }

  void _flushVip() {
    _vipAutosave?.cancel();
    _vipAutosave = null;
    if (!_vipDirty) return;
    _vipDirty = false;
    JsonFile.write(_vipFile, {
      'swaps': _swaps.map((k, v) => MapEntry(k, v.toJson())),
      'dead': _deadUntil,
    });
  }

  void _readVip(Object? raw) {
    if (raw is! Map) return;
    final swaps = raw['swaps'];
    if (swaps is Map) {
      swaps.forEach((k, v) {
        if (k is! String || v is! Map) return;
        try {
          _swaps[k] = Song.fromJson(Map<String, dynamic>.from(v));
        } catch (_) {}
      });
    }
    final dead = raw['dead'];
    if (dead is Map) {
      dead.forEach((k, v) {
        // 老版本这里存的是「标记时间」，恒在过去 → 读进来当场就过期，
        // 第一次访问时被 swapCheckedDead 清掉重来，不会把歌永久锁死。
        if (k is String && v is num) _deadUntil[k] = v.toInt();
      });
    }
  }

  // ---- 收藏的歌单（发现/搜索里的网易云歌单）--------------------------------
  //
  // 只存卡片那几个字段：曲目每次进详情页现取，歌单在网易云那边被改动过也能看到
  // 最新内容，代价是断网时打不开。

  final List<SheetInfo> _sheets = [];
  Set<String>? _sheetKeys;

  File get _sheetsFile => File('${_root.path}/sheets.json');

  List<SheetInfo> get savedSheets => List.unmodifiable(_sheets);

  bool isSheetSaved(SheetInfo s) =>
      (_sheetKeys ??= {for (final e in _sheets) e.key}).contains(s.key);

  /// 翻一次收藏状态：返回 true 表示这次是收藏上了。
  bool toggleSheet(SheetInfo s) {
    final before = _sheets.length;
    _sheets.removeWhere((e) => e.key == s.key);
    final added = _sheets.length == before;
    if (added) _sheets.insert(0, s);
    _writeSheets();
    return added;
  }

  List<SheetInfo> clearSheets() {
    final old = List<SheetInfo>.of(_sheets);
    if (old.isEmpty) return old;
    _sheets.clear();
    _writeSheets();
    return old;
  }

  /// 撤销 [clearSheets]。
  void restoreSheets(List<SheetInfo> sheets) {
    if (sheets.isEmpty) return;
    _sheets
      ..clear()
      ..addAll(sheets);
    _writeSheets();
  }

  void _writeSheets() {
    _sheetKeys = null;
    notifyListeners();
    JsonFile.write(_sheetsFile, _sheets.map((s) => s.toJson()).toList());
  }

  void _markDirty(LibraryKind kind) {
    _dirty[kind] = true;
    if (kind == LibraryKind.favorites) _favKeys = null;
    notifyListeners();
    _autosave?.cancel();
    _autosave = Timer(const Duration(seconds: 2), _flush);
  }

  void _flush() {
    _autosave?.cancel();
    _autosave = null;
    for (final kind in LibraryKind.values) {
      if (_dirty[kind] != true) continue;
      JsonFile.write(_file(kind), _by[kind]!.map((s) => s.toJson()).toList());
      _dirty[kind] = false;
    }
  }

  /// 切后台/退出前立刻落盘：2 秒防抖窗口里的收藏与最近播放不该被系统杀进程带走。
  void flushNow() {
    _flush();
    _statsAutosave?.cancel();
    _flushStats();
    _vipAutosave?.cancel();
    _flushVip();
    _writePaths();
    _writePlaylists();
  }
}
