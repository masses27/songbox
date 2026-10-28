import 'dart:async';

import '../../library/library_store.dart';
import '../../models/song.dart';
import '../../models/results.dart';
import '../../settings/app_settings.dart';
import '../../music_sdk/bl_source.dart';
import '../../music_sdk/kw_leaderboard.dart';
import '../../music_sdk/kw_native.dart';
import '../../music_sdk/kw_search.dart';
import '../../music_sdk/kg_native.dart';
import '../../music_sdk/tx_leaderboard.dart';
import '../../music_sdk/tx_native.dart';
import '../../music_sdk/tx_search.dart';
import '../../music_sdk/wy_catalog.dart';
import '../../music_sdk/wy_leaderboard.dart';
import '../../music_sdk/wy_native.dart';
import '../../music_sdk/wy_search.dart';
import '../../util/app_log.dart';
import '../../util/humanize.dart';
import '../../util/memo.dart';

/// Built-in music library: search / ranks / sheets.
///
/// Every playable URL here is fetched on-device; nothing depends on a
/// third-party source script. Catalog search is in-app too (wy/kw/tx/bl/kg).
/// It mirrors lx-music-mobile's musicSdk modules for the parts that work
/// anonymously.
class BuiltinLibrary {
  static final BuiltinLibrary instance = BuiltinLibrary._();
  BuiltinLibrary._();

  /// 目录缓存：榜单、推荐位这些一次要一两秒。
  final _catalog = Memo(ttl: const Duration(minutes: 5));

  /// 播放链接缓存。签名一次要一两秒，而同一首歌经常几秒内被再次点开
  /// （点两次列表项、上一首/下一首绕回来）。链接十几分钟就过期，所以窗口压到 3 分钟。
  final _urls = Memo(ttl: const Duration(minutes: 3));

  /// 歌词缓存：一首词几小时之内不会变，而切歌那一刻才去取，屏幕上就先空一秒。
  /// 预取下一首时顺手把词放进这里，真到切过去直接就有。
  final _lyrics = Memo(ttl: const Duration(hours: 6), maxEntries: 200);

  static String _urlKey(Song song, String quality) =>
      'url-${song.source}-${song.songmid}-$quality';

  /// 播放用这个而不是 [resolveUrl]：带缓存，且失败不会被记住。
  Future<String> cachedUrl(Song song, String quality) =>
      _urls.run(_urlKey(song, quality), () => resolveUrl(song, quality));

  /// 播放器用这个而不是 [resolveLyric]：带缓存。空歌词故意不入缓存——
  /// 接口偶尔就是返回一次空，记下来会把这首歌锁死在「暂无歌词」六小时。
  Future<LyricResult> cachedLyric(Song song) => _lyrics.run(
        'lyric-${song.source}-${song.songmid}',
        () async {
          final r = await resolveLyric(song);
          if (r.lyric.trim().isEmpty) throw Exception('这首歌没有歌词');
          return r;
        },
      );

  /// 播放器加载一条成功取到的链接却放不出来时调用，下次重试就会重新取一条。
  void forgetUrl(Song song, String quality) => _urls.remove(_urlKey(song, quality));

  /// 下拉刷新调用：清掉缓存，保证手动刷新一定能拿到新数据。
  void invalidateCatalog() => _catalog.clear();

  Future<SearchResult> search(String keyword, {String source = 'wy', int page = 1, int limit = 30}) async {
    switch (source) {
      case 'wy':
        return WySearch().search(keyword, page: page, limit: limit);
      case 'kw':
        return KwSearch().search(keyword, page: page, limit: limit);
      case 'tx':
        return TxSearch().search(keyword, page: page, limit: limit);
      default:
        throw Exception('搜索源 $source 尚未移植，当前支持 网易云(wy) / 酷我(kw) / QQ(tx)');
    }
  }

  /// 搜索联想（只有网易云有）：输入时实时查，不进缓存。
  Future<List<SuggestItem>> searchSuggest(String keyword) =>
      WySearch().suggest(keyword);

  /// 热搜词：搜索页空态，一天之内没必要变。
  Future<List<String>> hotWords() => _catalog.run('hot-words', WySearch.hotWords);

  /// 歌手 / 专辑 / 歌单 tabs of the search page. Only 网易云 has these result
  /// kinds; 酷我's endpoint answers with songs only.
  Future<({int total, List<ArtistInfo> list})> searchArtists(String keyword, {int page = 1}) =>
      WySearch().searchArtists(keyword, page: page);

  Future<({int total, List<AlbumInfo> list})> searchAlbums(String keyword, {int page = 1}) =>
      WySearch().searchAlbums(keyword, page: page);

  Future<({int total, List<SheetInfo> list})> searchSheets(String keyword, {int page = 1}) =>
      WySearch().searchSheets(keyword, page: page);

  /// 「含这首歌的歌单」：按歌名搜一批候选再逐张核对曲目表，怎么核、核几张都归
  /// WySearch 说，这里只给界面留一个入口。
  Future<({List<SheetInfo> list, bool verified, int checked})> sheetsHolding(
          String keyword, String songId) =>
      WySearch().sheetsHolding(keyword, songId);

  Future<({ArtistInfo artist, List<Song> songs})> artist(String id) =>
      _catalog.run('artist-$id', () => WyCatalog.artist(id));

  /// 歌手作品的后续页：第一页随 [artist] 一起回来，翻页走这个。
  Future<SearchResult> artistSongs(String id, {int page = 2}) =>
      _catalog.run('artist-songs-$id-$page', () => WyCatalog.artistSongs(id, page: page));

  Future<List<AlbumInfo>> artistAlbums(String id, {int page = 1}) =>
      _catalog.run('artist-albums-$id-$page', () => WyCatalog.artistAlbums(id, page: page));

  Future<({AlbumInfo album, List<Song> songs})> album(String id) =>
      _catalog.run('album-$id', () => WyCatalog.album(id));

  Future<List<RankInfo>> rankList(String source) => _catalog.run('ranks-$source', () async {
        switch (source) {
          case 'wy':
            return WyLeaderboard().list;
          case 'kw':
            return KwLeaderboard().list;
          case 'tx':
            return TxLeaderboard().list;
          default:
            throw Exception('榜单源 $source 尚未移植');
        }
      });

  Future<SearchResult> rankSongs(String source, String rankId, {int page = 1}) =>
      _catalog.run('rank-$source-$rankId-$page', () async {
        switch (source) {
          case 'wy':
            return WyLeaderboard().getList(rankId, page: page);
          case 'kw':
            return KwLeaderboard().getList(rankId, page: page);
          case 'tx':
            return TxLeaderboard().getList(rankId, page: page);
          default:
            throw Exception('榜单源 $source 尚未移植');
        }
      });

  /// 「换一批」靠 offset 往后挪，所以键必须带上 offset，否则换完还是那几张。
  Future<List<SheetInfo>> recommendedSheets({int limit = 12, int offset = 0}) =>
      _catalog.run('sheets-$limit-$offset', () => WyCatalog.recommendedSheets(limit: limit, offset: offset));

  /// 推荐新歌曲没有「换一批」：接口无视 offset，翻出来永远是同一批。
  Future<List<Song>> recommendedSongs({int limit = 30}) =>
      _catalog.run('newsong-$limit', () => WyCatalog.recommendedSongs(limit: limit));

  /// 发现页那排地区胶囊（接口词 → 界面上的字）。
  Map<String, String> get albumAreas => WyCatalog.albumAreas;

  /// 新碟上架。地区和页码都要进缓存键：不带 area 的话切到「日语」拿回来的还是
  /// 「全部」那批，不带 limit 的话「换一批」会拿到上一批的窗口。
  Future<List<AlbumInfo>> newAlbums({String area = 'ALL', int page = 1, int limit = 12}) =>
      _catalog.run('new-albums-$area-$page-$limit',
          () => WyCatalog.newAlbums(area: area, page: page, limit: limit));

  /// 热门歌手：认 offset，所以键带页码。
  Future<List<ArtistInfo>> topArtists({int page = 1, int limit = 12}) =>
      _catalog.run('top-artists-$page-$limit',
          () => WyCatalog.topArtists(page: page, limit: limit));

  /// 新歌速递：接口一次给满 100 首、不认 offset，所以只有一个键，
  /// 「换一批」由界面在这 100 首里切窗口。
  Future<List<Song>> freshSongs() => _catalog.run('fresh-songs', WyCatalog.freshSongs);

  /// 发现页横向那一排的常用分类。
  List<String> get sheetCategories => WyCatalog.quickCategories;

  /// 「全部分类」面板用的分组词表（语种/风格/场景/情感/主题）。
  List<SheetCategoryGroup> get sheetCategoryGroups => WyCatalog.categoryGroups;

  /// 分类歌单。排序永远按接口那套「热门」答，界面上不给开关：
  /// 2026-10-29 实测它的 `collect` 并非按收藏数排，摆出来是一颗会说谎的按钮。
  Future<List<SheetInfo>> sheets(String source, String category,
      {int page = 1, int limit = 30}) {
    if (source != 'wy') throw Exception('歌单分类目前只支持网易云曲库');
    return _catalog.run('hot-$category-$page-$limit',
        () => WyCatalog.hotSheets(category, page: page, limit: limit));
  }

  Future<SearchResult> sheetSongs(String source, String sheetId, {int page = 1}) {
    if (source != 'wy') throw Exception('歌单详情目前只支持网易云曲库');
    return _catalog.run('sheet-$sheetId-$page', () => WyCatalog.sheetSongs(sheetId, page: page));
  }

  /// 音质阶梯。网易云把 320k 和无损挡在会员后面，同一首的 128k 常常是免费的，
  /// 所以取不到时往下退一档再试：先让她听到，比报一个错有用。
  static List<String> _qualityLadder(String from) => switch (from) {
        'flac' => const ['flac', '320k', '128k'],
        '320k' => const ['320k', '128k'],
        _ => const ['128k'],
      };

  /// 换源候选值得按哪几档去问 —— 档位是**那个候选自己**的能力，不是原曲的设置。
  ///
  /// 复用原曲那张表在两处会错：
  /// - 会员墙那一步把 128k 从表里砍掉了（网易云三档一起挡，多问一遍只是白等），
  ///   可候选那边不一定有这一刀：拿砍过的表去问它，永远问不到它唯一有的那一档，
  ///   还要顺手打一周的「这首确实没有免费版」。
  /// - B 站、酷狗匿名整首各只给一个档位（`bl` 192k、`kg` 128k）：搜索回来的那个哈希
  ///   就是按那一档存的文件，问第二遍只是把同一条接口再打一次；整单体检并发跑的时候，
  ///   多出来的那一次就是撞限流的额度。
  /// 所以：只有一档的直接返回那一档，其余按「她要的那一档 + 最便宜的一档兜底」，最多两次。
  static List<String> twinLadder(Song twin, String quality) {
    final fixed = _oneShotTier[twin.source];
    if (fixed != null) return [fixed];
    final ladder = _qualityLadder(quality);
    return {ladder.first, ladder.last}.toList();
  }

  /// 匿名出整首、但只有死的一档的平台。搜到的哈希对应哪个码率，就只能出哪个码率。
  static const _oneShotTier = {'bl': '192k', 'kg': '128k'};

  /// 整条链子的时间上限。播放那边是 30 秒总超时，这里留出收尾的余量。
  static const _chainBudget = Duration(seconds: 22);

  /// 单次尝试最多愿意等多久（正常的取链一两秒就回，等太久的那次多半也不会成）。
  static const _tryBudget = Duration(seconds: 10);

  /// 端内自己就能取到整首的平台。判据要跟 [_attempt] 里的分支对上：
  /// 漏一个就等于这类歌白跑一趟换源，多写一个就会真发一次注定失败的请求。
  static const inAppSources = {'wy', 'tx', 'bl', 'kg'};

  /// Resolve a playable URL by walking an attempt chain: whatever the app can
  /// fetch on-device goes first. A quality that comes back empty steps down a
  /// tier and runs it again, and if the whole song is locked, the same track is
  /// looked for on the other platforms. Only when every one of those shots
  /// fails does the caller see an error — each stage contributes a line to the
  /// failure report.
  Future<String> resolveUrl(Song song, String quality) async {
    final F = _Failures();
    final deadline = DateTime.now().add(_chainBudget);

    // 上次为这首歌找到的那个版本第一步就能命中，不用再跑整条链子。
    // 取不到链接说明它也过期了，忘掉重来。
    final swap = LibraryStore.instance.swapSongFor(song);
    if (swap != null) {
      final url = await _attempt(swap, quality, F, deadline, prefix: '记住的版本 ${sourceName(swap.source)}：');
      if (url != null) return url;
      LibraryStore.instance.forgetSwapSong(song);
    }
    // 短期内确认过放不出的，直接说，别再让她等二十秒。
    // 这里的分支要和 [LibraryStore.markSwapDead] 打的那个标记同一判据：那条也是按
    // 「几个源都要会员」记 7 天的，只认网易云的话 QQ 那批会读出下面那句网络借口。
    if (LibraryStore.instance.swapCheckedDead(song)) {
      throw Exception(song.twinBlocked
          ? wallMessage(song, what: '同一首')
          : '这首几个源上都放不出，稍等一下会自动再试');
    }

    // fee=1 的歌在网易云端内是匿名请求，实测三档全部拿不到链接，降档只是把同一句
    // 「VIP 专属」再问一遍。直连整条跳掉，一步到位去换源。
    final ladder = _qualityLadder(quality);
    if (song.needsVip) {
      F.add('端内直连：VIP 专属（网易云这首要会员，直接去换源）');
    } else if (!inAppSources.contains(song.source)) {
      // 酷我的歌：端内只剩搜索和歌词，取链那条接口给的是 11 秒带水印的试听片段，
      // 放它出来比放不出更糟。所以这一首自己一步都不试，直接去别的曲库找同一首。
      F.add('酷我：端内只有搜索和歌词，要去别的曲库找同一首');
    } else {
      for (final q in ladder) {
        final url = await _attempt(song, q, F, deadline);
        if (url != null) return url;
        // 只有一档的平台（B 站 192k、酷狗 128k），退音质只是把同一条接口再问一遍。
        if (_oneShotTier.containsKey(song.source)) break;
        if (DateTime.now().isAfter(deadline)) break;
      }
    }

    // 会员墙后面往往就是另一平台的免费版；网易云自己的热单能省一半，靠的是这一步。
    for (final twin in await _findTwins(song, F, deadline: deadline)) {
      for (final q in twinLadder(twin, quality)) {
        final url = await _attempt(twin, q, F, deadline, prefix: '换源 ${sourceName(twin.source)}：');
        if (url != null) {
          // 记住这次的成功：下次同一首直接放这条，整首队列也不再撞墙。
          AppLog.add('换',
              '「${_short(song.name)}」换到 ${sourceName(twin.source)} 的「${_short(twin.name)}」拿到了链接');
          LibraryStore.instance.rememberSwapSong(song, twin);
          return url;
        }
        if (DateTime.now().isAfter(deadline)) break;
      }
    }

    // 「这首放不出」的标记一打就是几小时到一周，只有确确实实是歌的问题才配打：
    // 断网、风控算 flaky，跑到时间预算用完也算——那时候还有几条没试过呢。
    final mark = deadWarranted(F.flaky, DateTime.now(), deadline);
    AppLog.add('链', '「${_short(song.name)}」整条链子走完还是放不出：${F.lines.join(' / ')}');
    if (song.twinBlocked) {
      if (mark) _markDead(song);
      // 提示条上就带「换版本」按钮，这句话不必再教她怎么长按。
      throw Exception(wallMessage(song, what: '能放的同一版本'));
    }
    if (looksLikeVipWall(F.lines.join(' '))) {
      // 走到这儿原曲本身不是网易云的会员歌：那句「VIP」是某个换源候选说的（候选的
      // 台账也混在同一条 lines 里）。所以只说「几个源上都要会员」，别把酷我、B 站、
      // 酷狗那首报成网易云专享 —— 她照着去开网易云会员是白跑一趟。
      if (mark) _markDead(song);
      throw Exception('这首几个源上都要会员，没找到能播的免费版');
    }
    if (mark) _markDead(song);
    throw Exception('没能取到完整音频\n${F.lines.join('\n')}');
  }

  /// 「这首确实没有能播的版本」值不值得落成一条几天的标记。
  ///
  /// 播放和整单补测两条链子各判一次，抄两遍迟早会走样，所以抽出来：接口答了话
  /// （不是断网、不是风控），而且时间预算还没用完（没试过完的候选不算「没有」）。
  static bool deadWarranted(bool flaky, DateTime now, DateTime deadline) =>
      !flaky && now.isBefore(deadline);

  static void _markDead(Song song) {
    // 天数写在 [LibraryStore.markSwapDead] 里，这句只是把同一个判据念出来。
    AppLog.add('标', '「${_short(song.name)}」记为暂时放不出，'
        '${song.twinBlocked ? '7 天' : '12 小时'}后再问');
    LibraryStore.instance.markSwapDead(song);
  }

  static String _short(String s) => s.length <= 18 ? s : '${s.substring(0, 18)}…';

  /// 撞墙那句要说出是谁家的会员。`sourceName` 那张表里每家都有名字，而 `twinBlocked`
  /// 只有这三家会真，所以直接念来源就够了——不再各写一份「tx 就叫 QQ」的判断。
  static String _wallHome(Song song) => sourceName(song.source);

  /// 撞墙那句整句，两处撞墙（读到的旧标记、这一趟链子跑完）共用一份。
  ///
  /// 兜底名单要把墙本家自己剔掉：她从「找其他版本」里直接点酷狗那一首时，
  /// 「酷狗这首要会员，B 站、酷狗和别的源上也没找到」就成了自己数自己 ——
  /// 那条候选本来就是它，再说一遍只会让人以为还有第二条酷狗的路。
  static String wallMessage(Song song, {required String what}) {
    final home = _wallHome(song);
    final rescue = ['B 站', '酷狗'].where((h) => h != home).join('、');
    return '$home这首要会员，${rescue.isEmpty ? '别的源' : rescue}和别的源上也没找到$what';
  }

  /// 整单体检：把列表里所有会员歌一次性找一遍免费版本，结果直接落盘。
  ///
  /// 和「播到这首才撞墙」的区别是代价：正在放的这一首要抢时间，所以整条链子跑满
  /// 二十多秒；后台批量只要确认「这条能出链接」，每首最多两次搜索加一次取链。
  /// 并发限 2——一次几十首连着发出去，容易被平台当成爬虫。
  Future<({int fixed, int dead, int total})> scanVipSongs(List<Song> songs,
      {void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {
    final todo = LibraryStore.instance.vipNeedScan(songs);
    var done = 0, fixed = 0, dead = 0;
    for (var i = 0; i < todo.length; i += 2) {
      // 她换了队列就别再跑下去：剩下的那些马上要重新排一遍。
      if (cancelled?.call() ?? false) break;
      final batch = todo.sublist(i, (i + 2).clamp(0, todo.length));
      for (final ok in await Future.wait(batch.map(_probeVip))) {
        ok ? fixed++ : dead++;
        done++;
      }
      onProgress?.call(done, todo.length);
      if (i + 2 >= todo.length) break;
      // 一批推一批、中间不留空隙，四五个平台的搜索接口连着问几十遍，出口 IP
      // 看着就是爬虫——撞上一次限流，这一轮的歌全被判成「确实没有免费版」。
      await Future.delayed(const Duration(milliseconds: 1500));
      if (cancelled?.call() ?? false) break;
    }
    return (fixed: fixed, dead: dead, total: todo.length);
  }

  /// 一首：找到免费版本就存下来，确认没有就打标记。返回 true 表示找到了。
  Future<bool> _probeVip(Song song) async {
    final F = _Failures();
    final deadline = DateTime.now().add(const Duration(seconds: 18));
    final quality = AppSettings.instance.quality;
    for (final twin in await _findTwins(song, F, deadline: deadline)) {
      // 档位按候选判（和 resolveUrl 那条链子同一个条件）：只问设置里那一档，
      // 只有 128k 的那两家就永远问不到，体检完还要顺手打上「确实没有免费版」。
      for (final q in twinLadder(twin, quality)) {
        final url = await _attempt(twin, q, F, deadline, prefix: '体检 ${sourceName(twin.source)}：');
        if (url != null) {
          AppLog.add('补', '「${_short(song.name)}」备好 ${sourceName(twin.source)} 的免费版');
          LibraryStore.instance.rememberSwapSong(song, twin);
          return true;
        }
      }
    }
    // 搜索本身没回来、一路超时，或者 18 秒预算跑到头（那时候还有候选没试），
    // 都不该打「确认没有」的标记——否则网络一恢复，这首还要被跳过整整一周。
    if (deadWarranted(F.flaky, DateTime.now(), deadline)) _markDead(song);
    return false;
  }

  /// 一首歌、一个音质：走端内那几条直连。拿不到返回 null，原因已经记进台账。
  Future<String?> _attempt(Song song, String quality, _Failures F, DateTime deadline,
      {String prefix = ''}) async {
    final budget = _remaining(deadline);
    if (budget == null) return null;
    if (!inAppSources.contains(song.source)) {
      // 能走到这一格的只有「上次记住的版本」：她机器上那条记录可能是酷我那一首，
      // 当年还有音源脚本能替它取整首。那条路已经拆了，一句话交代完就走，
      // 别真发一次注定失败的请求出去。
      F.add('$prefix酷我：端内只有搜索和歌词，没有取整首的路');
      return null;
    }
    if (song.source == 'bl') {
      // B 站这条只有一档（匿名 192k 整首），音质在这儿不是变量。
      try {
        return await BlSource.resolveUrl(song.songmid).timeout(budget);
      } catch (e) {
        F.addError('${prefix}B 站整首：', e, brief: e is TimeoutException ? '等待超时' : null);
      }
      return null;
    }
    if (song.source == 'wy') {
      // 网易云不再带登录态，会员歌匿名请求一定撞 -110：这一档直接跳过，
      // 交给 B 站、酷狗那两条整首，别在这儿白跑一次网络。
      if (song.needsVip) {
        F.add('$prefix端内直连：VIP 专属（网易云这首要会员）');
      } else {
        try {
          return await WyNative.resolveUrl(song.songmid, quality: quality).timeout(budget);
        } catch (e) {
          F.addError('$prefix端内直连：', e, brief: e is TimeoutException ? '等待超时' : null);
        }
      }
    }
    if (song.source == 'tx') {
      try {
        return await TxNative.resolveUrl(song.songmid, quality: quality).timeout(budget);
      } catch (e) {
        F.addError('${prefix}QQ 直连：', e, brief: e is TimeoutException ? '等待超时' : null);
      }
    }
    if (song.source == 'kg') {
      // 酷狗这条也只有一档：搜索回的那个哈希就是 128k 那一份文件，音质在这儿不是变量。
      try {
        return await KgNative.resolveUrl(song.songmid).timeout(budget);
      } catch (e) {
        F.addError('$prefix酷狗整首：', e, brief: e is TimeoutException ? '等待超时' : null);
      }
    }
    return null;
  }

  /// 还剩多少时间可用；不够一次像样的尝试就返回 null。
  static Duration? _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left.inMilliseconds < 1500) return null;
    return left.compareTo(_tryBudget) > 0 ? _tryBudget : left;
  }

  /// 换源候选：网易云自己库里同一首歌常有第二条不花钱的 id（精选集、重新上架），
  /// 先试它，再试 QQ，最后是 B 站、酷狗这两条「匿名整首」。
  /// 返回最多两条，调用方按顺序逐条取链。
  ///
  /// 候选只从 [inAppSources] 那几家里挑。酷我的名额已经撤掉：它端内取不到整首，
  /// 占进去的那一条等于白等一次失败，还会把一家能播的候选挤出这两格。
  ///
  /// [deadline] 是调用方那条链子的时间预算：找候选这一步本身要发四五个搜索请求，
  /// 预算用完了还继续发，拿回来的候选也来不及取链，白白多撞几次平台的频率限制。
  Future<List<Song>> _findTwins(Song song, _Failures F, {DateTime? deadline}) async {
    final keyword = '${song.name} ${song.singer}'.trim();
    if (keyword.isEmpty) return const [];
    final out = <Song>[];
    Future<void> searchOn(String target) async {
      if (out.length >= 2) return;
      if (deadline != null && DateTime.now().isAfter(deadline)) return;
      final label = sourceName(target);
      try {
        final picked = target == 'bl'
            // B 站的门槛写在 BlSource 里：标题得同时出现曲名和歌手，明写了翻唱、伴奏、
            // KTV 的不要。交回来时曲名歌手已经换成原来那一首，再过一遍通用打分只会原样通过。
            ? await BlSource.findTwins(song.name, song.singer, wantSec: song.interval, max: 2 - out.length)
            : pickTwins(
                switch (target) {
                  'tx' => (await TxSearch().search(keyword, limit: 10)).list,
                  'kg' => await KgNative.searchSongs(keyword, limit: 10),
                  _ => (await WySearch().search(keyword, limit: 10)).list,
                },
                song,
                max: 2 - out.length,
              );
        out.addAll(picked);
        if (out.isEmpty) F.add('换源：$label 上没找到同一首歌');
      } catch (e) {
        F.addError('换源：$label 搜索失败：', e);
      }
    }

    // 撞在会员墙后面的歌，端内和 QQ 都要会员，还肯匿名出整首、命中又高的只有 B 站：
    // 这种歌把它排第一个，省下的是她等换源的那几秒。判据用 `twinBlocked`——QQ 的
    // 会员歌撞的是同一堵墙，按网易云算的话那一半还是最后才轮到 B 站。
    if (song.twinBlocked) await searchOn('bl');
    if (song.source == 'wy') await searchOn('wy');
    for (final t in ['tx', 'wy']) {
      if (t != song.source) await searchOn(t);
    }
    if (!song.twinBlocked) await searchOn('bl');
    // 酷狗最后上场，而且只在前面几家空手而归的时候：它比 B 站还低一档（128k），
    // 免费曲又窄（抽 13 首热单只有 2 首匿名给整首），换来的却是一次多花的搜索加取链。
    // 前面任何一家已经给出候选，就让它去试那条，别为这点命中率再拖一两秒。
    if (out.isEmpty) await searchOn('kg');
    return out;
  }

  /// 「找其他版本」列表：同一首歌在网易云的其他版本（现场、Live、翻唱、remix），
  /// 以及另一平台的同名。判定比自动换源松得多——这里由她本人挑，
  /// 自动换源怕「放错了」所以只认同一版本。
  ///
  /// 摆出来的每一条都得是她点下去就有声音的那类，所以只有能端内取整首的几家：
  /// 酷我的行点开会走一次换源，运气好放出的是别家同名，运气不好就是一场空等。
  Future<List<Song>> otherVersions(Song song) async {
    final keyword = '${song.name} ${song.singer}'.trim();
    if (keyword.isEmpty) return const [];
    final found = <Song>[];
    try {
      found.addAll((await WySearch().search(keyword, limit: 20)).list);
    } catch (_) {}
    try {
      found.addAll((await TxSearch().search(keyword, limit: 10)).list);
    } catch (_) {}
    try {
      // 「这首放不出」的时候长按找版本，B 站那条整首也该摆在她能挑的列表里。
      found.addAll(await BlSource.findTwins(song.name, song.singer, wantSec: song.interval, max: 6));
    } catch (_) {}
    try {
      // 酷狗同理：匿名给整首的那 128k 也是一条能放的路，挡在墙后面的会带会员角标。
      found.addAll(await KgNative.searchSongs(keyword, limit: 10));
    } catch (_) {}
    return pickTwins(found, song, max: 24, loose: true);
  }

  /// 从另一平台的搜索结果里挑「就是这一首」的那条。
  ///
  /// 歌名认不出、歌手不重合的直接否掉；时长差太多的扣分——那多半是现场版或
  /// remix，放错了比放不出更让人莫名其妙。4.5 这条线大致等于「歌名全等 + 歌手
  /// 沾边」或「歌名沾边 + 歌手全等 + 时长接近」。
  /// 除此之外还有一道版本关：纯音乐、降调、DJ、别人翻唱、乱码上传直接否掉，
  /// 现场版只扣分，让录音室版本顶上来。
  ///
  /// [loose] 是给「找其他版本」用的：那时候现场版、翻唱恰恰是我们要的东西，
  /// 所以只按相关度排序，不再拿时长和会员标记筛掉。
  static Song? pickTwin(List<Song> candidates, Song want) {
    final list = pickTwins(candidates, want, max: 1);
    return list.isEmpty ? null : list.first;
  }

  static List<Song> pickTwins(List<Song> candidates, Song want, {int max = 1, bool loose = false}) {
    final name = _fold(want.name);
    final singer = _fold(want.singer);
    if (name.isEmpty) return const [];
    final scored = <({Song song, double score})>[];
    for (final c in candidates) {
      if (!loose && c.twinBlocked) continue; // 换源目标是「能播」，会员墙后面的不算
      if (c.source == want.source && c.songmid == want.songmid) continue; // 就是它自己
      final s = _twinScore(c, want, name, singer, loose: loose);
      if (s == null) continue;
      // 自动换源保持原来 4.5 这条保守线；「找其他版本」是人来挑，不做淘汰。
      if (!loose && s < 4.5) continue;
      scored.add((song: c, score: s));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(max).map((e) => e.song).toList();
  }

  /// null 表示这条直接否掉。
  static double? _twinScore(Song c, Song want, String name, String singer, {bool loose = false}) {
    final cn = _fold(c.name);
    if (cn.isEmpty) return null;
    // 括号里的版本说明（Live、钢琴版）和常见的年份/版本后缀单独去掉，剩下的算「核心歌名」：
    // 「江南 (Live)」和「江南」是同一首歌的不同录音。
    final core = _coreName(c.name);
    final coreWant = _coreName(want.name);
    final sameCore = core.isNotEmpty && core == coreWant;
    if (cn != name && !(cn.contains(name) || name.contains(cn)) && !sameCore) return null;
    var score = cn == name ? 3.0 : (sameCore ? 2.2 : 1.5);
    final cs = _fold(c.singer);
    if (singer.isEmpty || cs.isEmpty) {
      score += 0.5;
    } else if (cs == singer) {
      score += 3;
    } else if (cs.contains(singer) || singer.contains(cs)) {
      score += 1.5;
    } else if (!loose) {
      return null;
    } else {
      score += 0.3; // 翻唱：相关度低，但让她自己判断
    }
    final a = want.interval ?? 0;
    final b = c.interval ?? 0;
    if (a > 0 && b > 0) {
      final d = (a - b).abs();
      if (d <= 5) {
        score += 2;
      } else if (d > 20) {
        score -= loose ? 0.5 : 3;
      }
    }
    // 版本标记放在最后：它决定的是「能不能自动放」，不是「像不像同一首」。
    final mark = _versionMark(c.name);
    if (mark != 'none') {
      if (mark == 'live') {
        score -= loose ? 0.4 : 0.8; // 现场版是另一个录音：原版一定排在它前面，实在没有才用它
      } else if (!loose) {
        return null;
      } else {
        score -= 2; // 「找其他版本」里还要给这些，只是排在原版后面
      }
    }
    return score;
  }

  /// 歌名里的版本线索，只从括号段和结尾尾巴取，免得把歌名本身叫《伴奏》的正常歌曲误伤。
  ///
  /// `none` 没有标记；`live` 现场/演唱会；`alt` 纯音乐、降调、DJ、翻唱这类「不是原版」；
  /// `junk` 上传者自己写的乱码；`unknown` 括号里既不是版本也不是年份，多半是别人的名字
  /// （`当你 (熊先生)` 就是有人把翻唱传成了原唱）。
  static String _versionMark(String raw) {
    if (_junkName.hasMatch(raw)) return 'junk';
    final parens = _parenParts.allMatches(raw).map((m) => m.group(0)!).join(' ').toLowerCase();
    if (_junkTag.hasMatch(parens)) return 'junk';
    final stripped = _fold(raw.replaceAll(_parenParts, ' '));
    final tag = '$parens${_versionTail.firstMatch(stripped)?.group(0) ?? ''}';
    if (tag.isEmpty) return 'none';
    if (_altTag.hasMatch(tag)) return 'alt';
    if (_liveTag.hasMatch(tag)) return 'live';
    if (_dateOnly.hasMatch(tag)) return 'none';
    return parens.isEmpty ? 'none' : 'unknown';
  }

  /// 自动换源不能放的分支版本。
  static final RegExp _altTag = RegExp(
      r'纯音乐|伴奏|伴唱|instrumental|karaoke|off ?vocal|无人声|降调|升调|变调|加速|放慢|慢速|'
      r'dj|remix|混音|变奏|edit|钢琴版|钢琴曲|古筝|二胡|大提琴|小提琴|八音盒|音乐盒|竖琴|'
      r'翻唱|cover|清唱|独唱|a ?cappella|片段|试听|预听|采样|纯享|demo',
      caseSensitive: false);

  static final RegExp _liveTag = RegExp(r'live|现场|演唱会|concert|版', caseSensitive: false);

  /// 上传者自己乱写的花名：一长串分隔符，或者后面拖一串省略号。
  static final RegExp _junkName = RegExp(r'[-—－~～]{3,}|[。．.]{3,}|…|等\d+首');

  /// 括号里塞进整句推荐语（《歌名》、一串点）的也是垃圾上传。
  static final RegExp _junkTag = RegExp(r'《.+》|[-—－~～]{2,}');

  /// 只有年份/日期的括号（(2013)）不是分支版本，那是同一首录音的重制再发行。
  static final RegExp _dateOnly = RegExp(r'^[\s\d年月日（）()【】\[\]～~—\-]+$');

  static final RegExp _parenParts = RegExp(r'[（(【\[][^）)】\]]*[）)】\]]');
  static final RegExp _versionTail = RegExp(
      r'(live|现场|伴奏|纯音乐|翻唱|cover|remix|钢琴版|版|demo|\d{4})+$',
      caseSensitive: false);

  /// 去掉括号段和版本后缀，得到用来比「是不是同一首歌」的核心名。
  static String _coreName(String raw) {
    final stripped = raw.replaceAll(_parenParts, ' ');
    return _fold(stripped).replaceAll(_versionTail, '');
  }

  static final RegExp _twinNoise = RegExp(r"[\s\-－_·．.,，、()（）\[\]【】/｜'’]");

  static String _fold(String s) => s.toLowerCase().replaceAll(_twinNoise, '');

  static String _shortErr(Object e) {
    final s = '$e';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// 歌词也只走端内直连：三家有自己的词接口，B 站和酷狗靠同一首的网易云条目配词。
  Future<LyricResult> resolveLyric(Song song) async {
    if (song.source == 'bl' || song.source == 'kg') {
      // 这两家只肯给整首音频，我们没有可匿名读的词接口（B 站本来就没有，酷狗那个要签名）。
      // 它就是同一首歌：拿曲名歌手去网易云搜一条对得上的来配词。
      // 到这儿就收尾——搜不到对得上的那条，这一首就是没词，再问别家也是白问。
      try {
        final found = (await WySearch().search('${song.name} ${song.singer}'.trim(), limit: 5)).list;
        final twin = pickTwin(found, song);
        if (twin != null) {
          final wy = await WyNative.resolveLyric(twin.songmid);
          if (wy.lyric.trim().isNotEmpty) return wy;
        }
      } catch (_) {}
      return LyricResult(lyric: '');
    }
    if (song.source == 'kw' || song.source == 'wy' || song.source == 'tx') {
      try {
        final direct = switch (song.source) {
          'wy' => await WyNative.resolveLyric(song.songmid),
          'tx' => await TxNative.resolveLyric(song.songmid),
          _ => LyricResult(lyric: await KwNative.resolveLyric(song.songmid)),
        };
        if (direct.lyric.trim().isNotEmpty) return direct;
      } catch (_) {}
    }
    return LyricResult(lyric: '');
  }
}

/// 一次取链过程的失败台账。
///
/// 两份用处：每行都要能在报错里读得通；同时得留得住「这次到底是歌的问题
/// 还是网的问题」——断网、风控、整条链子跑到超时都不该被打成「这首放不出」，
/// 那个标记一落就是几小时起，网好了歌还被跳过。
class _Failures {
  final lines = <String>{};

  /// 有没有任何一次失败像是网络造成的。
  bool flaky = false;

  void add(String line) => lines.add(line);

  /// [brief] 给出时用它替掉原始异常文本（界面上「等待超时」比一串
  /// DioException 好读），但归类仍然按原始异常判。
  void addError(String prefix, Object e, {String? brief}) {
    lines.add('$prefix${brief ?? BuiltinLibrary._shortErr(e)}');
    // 连不上和「这次问得不凑巧」都算不稳：这两种情况下还有候选没试完，
    // 打「确认没有免费版」的标记会把一首好歌跳过整整一周。
    if (looksLikeNetworkFailure(e) || looksLikeThrottle(e)) flaky = true;
  }
}
