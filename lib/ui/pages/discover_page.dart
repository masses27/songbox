import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../library/library_store.dart';
import '../../library/taste_profile.dart';
import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../rank_groups.dart';
import '../widgets.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'artist_roster_page.dart';
import 'builtin_library.dart';
import 'rank_detail_page.dart';
import 'sheet_detail_page.dart';
import '../theme.dart';

/// 首页那两枚入口（宫格「排行榜」、区块头「全部榜单」）跳到这一页时要做的事：
/// 把收起来的分组摊开，再把视线送到榜单那一块。以前发现页把 60 多个榜平铺，
/// 跳过来只做了一半；现在榜单收起来一格，不滚过去就等于没跳到。
abstract class ShowAllRanks {
  void showAllRanks();
}

/// 发现 — playlist categories plus the full ranking list.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> implements ScrollToTop, ShowAllRanks {
  static const _rankSources = ['wy', 'kw', 'tx'];
  final ScrollController _scroll = ScrollController();
  // 下拉刷新时歌单分类那一块也要跟着重取，不然它还拿着刚才被清掉的旧数据。
  final _sheetBlockKey = GlobalKey<_SheetCategoriesState>();
  // 三块新板块同理：缓存刚清掉，它们各自重新取一次。
  final _freshBlockKey = GlobalKey<_StripState<Song>>();
  final _albumBlockKey = GlobalKey<_StripState<AlbumInfo>>();
  final _artistBlockKey = GlobalKey<_StripState<ArtistInfo>>();
  // 口味那一排也一样，但它还要把整池候选丢掉重搜（见 [_tastePool]）。
  final _tasteBlockKey = GlobalKey<_StripState<Song>>();
  // 榜单那一块的起点：从首页「全部榜单」跳过来要滚到这里。
  final _rankBlockKey = GlobalKey();
  List<RankInfo> _ranks = const [];
  String _rankSource = 'wy';
  bool _loading = false;

  /// 只有第一组（一般是官方主榜）常驻，其余几组收在这颗开关后面。
  /// 以前 60 多个榜铺成三列宫格，光榜单就是二十多行、四屏多的地方，
  /// 一页里歌单和榜单两边都看不全。
  bool _moreRanks = false;
  String? _error;

  /// 换榜单源、下拉刷新会各起一次请求，回来的顺序不讲道理：只认最后发起那一趟，
  /// 不然慢的那趟把刚切好的源盖回旧榜单。
  int _loadGen = 0;

  /// 口味那一排的「按谁挑的」，空表示这台手机还没听出口味，整块不出现。
  List<String> _tasteNames = const [];

  /// 口味那一排的候选池：搜一次留着，「换一批」在池子里切窗口，不再重搜。
  List<Song>? _tastePool;

  @override
  void initState() {
    super.initState();
    _readTaste();
    _load();
  }

  /// 从本机听歌记录里读出口味的前几位。这一层是同步的（[LibraryStore.taste] 只算内存里
  /// 那几份表），所以可以直接在 initState 里读，不用等网络。
  void _readTaste({bool notify = false}) {
    final names = LibraryStore.instance.taste().topArtists(3);
    _tastePool = null;
    if (notify) {
      setState(() => _tasteNames = names);
    } else {
      _tasteNames = names;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  @override
  void showAllRanks() {
    if (!_moreRanks) setState(() => _moreRanks = true);
    // 摊开的那一帧之后才量得到新位置，同一帧里滚用的是旧布局。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rankBlockKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx,
          alignment: 0, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    });
  }

  Future<void> _load({bool refresh = false}) async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lib = BuiltinLibrary.instance;
      if (refresh) {
        lib.invalidateCatalog();
        _sheetBlockKey.currentState?.reload();
        _freshBlockKey.currentState?.reload();
        _albumBlockKey.currentState?.reload();
        _artistBlockKey.currentState?.reload();
        // 口味是听出来的：这几天多听了几首，下拉一次就该换人顶上，池子整个重搜。
        _readTaste(notify: true);
        _tasteBlockKey.currentState?.reload();
      }
      final list = await lib.rankList(_rankSource);
      if (mounted && gen == _loadGen) setState(() => _ranks = list);
    } catch (e) {
      if (mounted && gen == _loadGen) setState(() => _error = humanizeError(e));
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  void _swapSource(String s) {
    if (_rankSource == s) return;
    setState(() {
      _rankSource = s;
      _ranks = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupRanks(_ranks);
    // 第一组常驻，其余等她要；只有一组的时候连那颗开关都不摆。
    final shown = _moreRanks ? groups : groups.take(1).toList();
    final rest = groups.length > 1 ? groups.length - 1 : 0;
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('发现', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                    const SizedBox(height: 4),
                    // 这一行是把屏幕上有的板块挨个点一遍，所以口味那一块没出现时不能提它：
                    // 写着一排她找不到东西的名字，等于让页脚替界面说谎。
                    Text(_tasteNames.isEmpty
                        ? '新歌 · 新碟 · 歌手 · 歌单 · 榜单'
                        : '口味 · 新歌 · 新碟 · 歌手 · 歌单 · 榜单',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
          if (_tasteNames.isNotEmpty)
            SliverToBoxAdapter(
              child: _Strip<Song>(
                key: _tasteBlockKey,
                title: '按你的口味',
                hint: '你听得最多的是 ${_tasteNames.join('、')}，这一排是他们别的歌',
                height: 132,
                load: (page, _) => _tasteWindow(page),
                tile: (context, s, batch) => SongCard(song: s, batch: batch, onTap: _play),
              ),
            ),
          SliverToBoxAdapter(
            child: _Strip<Song>(
              key: _freshBlockKey,
              title: '新歌速递',
              height: 132,
              load: (page, _) => _freshWindow(page),
              tile: (context, s, batch) => SongCard(song: s, batch: batch, onTap: _play),
            ),
          ),
          SliverToBoxAdapter(
            child: _Strip<AlbumInfo>(
              key: _albumBlockKey,
              title: '新碟上架',
              height: 152,
              tabs: BuiltinLibrary.instance.albumAreas,
              load: (page, area) =>
                  BuiltinLibrary.instance.newAlbums(area: area, page: page, limit: _stripSize),
              tile: (context, a, _) => _AlbumCard(album: a),
            ),
          ),
          SliverToBoxAdapter(
            child: _Strip<ArtistInfo>(
              key: _artistBlockKey,
              title: '热门歌手',
              height: 100,
              load: (page, _) => BuiltinLibrary.instance.topArtists(page: page, limit: _stripSize),
              tile: (context, a, _) => _ArtistCard(artist: a),
            ),
          ),
          const SliverToBoxAdapter(child: _RosterEntry()),
          SliverToBoxAdapter(child: _SheetCategories(key: _sheetBlockKey)),
          SliverToBoxAdapter(
            child: SectionHeader('榜单',
                key: _rankBlockKey,
                actionText: rest == 0 ? null : (_moreRanks ? '收起榜单' : '还有 $rest 组榜单'),
                onAction: rest == 0 ? null : () => setState(() => _moreRanks = !_moreRanks)),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final s in _rankSources)
                    ChoiceChip(
                      label: Text(sourceLabel(s), style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      selected: _rankSource == s,
                      selectedColor: AppTheme.primary.withValues(alpha: .15),
                      onSelected: (_) => _swapSource(s),
                    ),
                ],
              ),
            ),
          ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    // 就地给一颗重试：这句错误光是写在那里，她能做的只有把整页下拉一遍，
                    // 而那一下把分类歌单也一起重取。
                    Expanded(
                      child: Text(
                          // 榜还在屏上时说的是「这一批是什么时候的」，不是「失败了」了事。
                          _ranks.isEmpty ? '榜单加载失败：$_error' : '这些是上次拉的：$_error',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppTheme.primary, fontSize: 12)),
                    ),
                    TextButton(
                        onPressed: _load,
                        child: const Text('重试', style: TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
          if (_loading && _ranks.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))),
          for (final g in shown) ...[
            SliverToBoxAdapter(child: SectionHeader(g.title)),
            SliverToBoxAdapter(child: _RankStrip(ranks: g.ranks, onTap: _openRank)),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  void _openRank(RankInfo rank) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RankDetailPage(
          title: rank.name,
          load: (page) => BuiltinLibrary.instance.rankSongs(rank.source, rank.id, page: page),
        ),
      ),
    );
  }

  /// 点一格新歌就地播：队列起在底部播放条上，不跳播放页（和首页那一排同一个动作）。
  /// 队列是屏幕上这一批，不是接口给的一百首 —— 她按下去看到的是哪几首，往下就是哪几首。
  void _play(Song song, List<Song> batch) =>
      context.read<PlayerService>().playList(batch, batch.indexOf(song));

  /// 新歌速递的「换一批」在接口一次给回的那一百首里切窗口：那条接口不认翻页
  /// （实测 `area`、`offset` 都是摆设），但 [BuiltinLibrary.freshSongs] 那五分钟
  /// 缓存让第二屏不要钱。切到头交空列表，由板块自己绕回第一批。
  Future<List<Song>> _freshWindow(int page) async {
    final all = await BuiltinLibrary.instance.freshSongs();
    final from = (page - 1) * _stripSize;
    if (all.isEmpty || from >= all.length) return const [];
    return all.skip(from).take(_stripSize).toList();
  }

  /// 口味那一排的「换一批」同样是在池子里切窗口——那一池是她最常听的那几位在网易云上的
  /// 歌，搜一次就够，翻到没有交空列表，由板块自己绕回第一批。
  Future<List<Song>> _tasteWindow(int page) async {
    final pool = _tastePool ??= await _tastePoolSongs();
    final from = (page - 1) * _stripSize;
    if (pool.isEmpty || from >= pool.length) return const [];
    return pool.skip(from).take(_stripSize).toList();
  }

  /// 她听得最多的那几位，各自在网易云上的一批热门歌，一位拿一首轮着排。
  ///
  /// 为什么要筛：按歌手名搜出来的东西并不都挂着那位（撞名的、翻唱的、合集里塞的），
  /// 所以每一首都要有这位署名才留下；她已经收藏过的、这几天刚听过的也不端上来——
  /// 那些她库里就有，再推一遍只显得推荐没在动。
  /// 某一位的搜索挂了不算整块失败：剩下两位照样能凑一排，全挂了才报「没拉到」让她重试。
  Future<List<Song>> _tastePoolSongs() async {
    final store = LibraryStore.instance;
    final taste = store.taste();
    final names = _tasteNames;
    if (names.isEmpty) throw Exception('还没听出口味来');
    final wanted = {for (final n in names) Taste.normalizeArtist(n)};
    final skip = {...taste.wornOut, ...taste.heardRecently};
    Future<List<Song>> one(String n) async {
      try {
        return (await BuiltinLibrary.instance.search(n, source: 'wy', limit: 20)).list;
      } catch (_) {
        return const <Song>[];
      }
    }

    final batches = await Future.wait([for (final n in names) one(n)]);
    final seen = <String>{};
    final out = <Song>[];
    // 轮着取：一位连取十二首的话，这一排就成了一个人的精选集，另外两位白搜。
    for (var at = 0; at < 20; at++) {
      for (final b in batches) {
        if (at >= b.length) continue;
        final s = b[at];
        if (!Taste.artistsOf(s).any(wanted.contains)) continue;
        if (seen.contains(Taste.keyOf(s)) || skip.contains(Taste.keyOf(s))) continue;
        if (store.isFavorite(s)) continue;
        seen.add(Taste.keyOf(s));
        out.add(s);
      }
    }
    if (out.isEmpty) throw Exception('网易云上没搜到这几位的歌');
    // 一按就出声的排前面：这一排是顺手点的，塞满要绕整条换源链子的那种，
    // 她的感受就是「怎么点三首有两首在转圈」。已经备好免费版的会员歌算这一档。
    bool playable(Song s) => !s.twinBlocked || store.hasSwapSong(s);
    final good = out.where(playable).toList();
    return [...good, ...out.where((s) => !playable(s))];
  }
}

/// 发现页三块新板块一屏摆几个，「换一批」每次也正好挪这么多个。
const _stripSize = 12;

/// 发现页一块横向板块：标题、可选的一排胶囊、「换一批」、坏了就地重试。
///
/// 新歌速递 / 新碟上架 / 热门歌手要的动作完全一样 —— 进来自己取一次、父页下拉刷新
/// 跟着重取、往后挪到头绕回第一批、坏了只在这一格里吭一声 —— 差别只有拿什么数据、
/// 每格画成什么样，所以收成一个泛型组件，不把那段状态机抄三遍。
class _Strip<T> extends StatefulWidget {
  const _Strip({
    super.key,
    required this.title,
    required this.load,
    required this.tile,
    required this.height,
    this.tabs = const {},
    this.hint,
  });

  final String title;

  /// 标题下面那一行小字（「按你的口味」要说清是按谁挑的）。标题那一排放不下长句：
  /// 360 宽的屏上，标题再加长就要和右边的「换一批」抢地方。
  final String? hint;

  /// 取第 [page] 批（从 1 起）。没摆胶囊的板块拿到的 [tab] 是空串。
  final Future<List<T>> Function(int page, String tab) load;

  /// 画一格。[batch] 是屏幕上这一批 —— 点下去要起队列的那类板块用它当队列。
  final Widget Function(BuildContext context, T item, List<T> batch) tile;

  /// 横向 ListView 要一个有限高度：封面那一边加上下面两三行字。
  final double height;

  /// 标题下面那排胶囊（新碟的地区）：接口认的词 → 界面上的字。空的话不摆这一排。
  final Map<String, String> tabs;

  @override
  State<_Strip<T>> createState() => _StripState<T>();
}

class _StripState<T> extends State<_Strip<T>> {
  List<T> _items = const [];
  int _page = 1;
  String _tab = '';
  bool _loading = false;
  bool _swapping = false;
  String? _error;

  /// 连点几个胶囊再搭上拉刷新就是几趟并发请求，回来的先后看网络：只认最后发起那趟。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _tab = widget.tabs.isEmpty ? '' : widget.tabs.keys.first;
    _load();
  }

  /// 父页下拉刷新时叫一声：缓存已经被清掉，这一格重新取当前那一档。
  void reload() => _load();

  Future<void> _load() async {
    final gen = ++_gen;
    final tab = _tab;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
    });
    try {
      final list = await widget.load(1, tab);
      if (mounted && gen == _gen) setState(() => _items = list);
    } catch (e) {
      if (mounted && gen == _gen) {
        // 屏上那批别清：下拉刷新撞上网络抖一下，原来会把她已经在看的一排封面整个
        // 抹成一句报错。留着旧的，只在下面补一行「这是上次那批」，重试就在旁边。
        setState(() => _error = humanizeError(e));
      }
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  /// 往后挪一批；接口不再给东西就是挪到头了，绕回第一批（那一批还在缓存里，
  /// 不会再发一次请求），别让她点了颗没动静的按钮。
  Future<void> _swap() async {
    if (_swapping || _items.isEmpty) return;
    final gen = _gen;
    final tab = _tab;
    setState(() => _swapping = true);
    try {
      var at = _page + 1;
      var list = await widget.load(at, tab);
      if (list.isEmpty) {
        at = 1;
        list = await widget.load(at, tab);
      }
      // 等的这一会儿她可能已经换了档或重拉过：那这批就不是当前这一档的答案了。
      if (!mounted || gen != _gen || list.isEmpty) return;
      _page = at;
      setState(() => _items = list);
    } catch (e) {
      // 换失败原来那批还在，但要吭一声，不然点了没动静看着像按钮坏了。
      if (mounted) toast(context, '这批没换出来：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
  }

  void _pickTab(String t) {
    if (t == _tab) return;
    setState(() {
      _tab = t;
      _items = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(widget.title,
            actionText: _items.isEmpty ? null : (_swapping ? '正在换…' : '换一批'),
            onAction: _swapping || _items.isEmpty ? null : _swap),
        if (widget.hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(widget.hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ),
        if (widget.tabs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Wrap(
              spacing: 8,
              children: [
                for (final e in widget.tabs.entries)
                  ChoiceChip(
                    label: Text(e.value, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    selected: _tab == e.key,
                    selectedColor: AppTheme.primary.withValues(alpha: .15),
                    onSelected: (_) => _pickTab(e.key),
                  ),
              ],
            ),
          ),
        if (_loading && _items.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(child: CircularProgressIndicator()))
        else ...[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  // 就地给一颗重试：这句错误光写在那里，她能做的只有把整页下拉一遍，
                  // 而那一下把五块内容一起重取。
                  Expanded(
                    child: Text(
                        // 旧批次还在屏上时不能说「没拉到」就算完 —— 那几格是上一次的，
                        // 得让她知道现在看到的是什么时候的东西。
                        _items.isEmpty
                            ? '${widget.title}没拉到：$_error'
                            : '这批是上次那批：$_error',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
                  ),
                  TextButton(onPressed: _load, child: const Text('重试', style: TextStyle(fontSize: 13))),
                ],
              ),
            ),
          if (_items.isNotEmpty)
            SizedBox(
              height: widget.height,
              child: MouseDragScroll(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => widget.tile(context, _items[i], _items),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// 一碟一格：封面、碟名、歌手。点开是专辑页 —— 那儿才有整张碟的曲目。
class _AlbumCard extends StatelessWidget {
  final AlbumInfo album;
  const _AlbumCard({required this.album});

  static const _side = 108.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _side,
      child: GestureDetector(
        // 整格都认点击：她眼睛盯着的是碟名，手指也点在那儿。
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AlbumPage(albumId: album.id, seedName: album.name)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverTile(label: '', imageUrl: album.pic, size: _side, seedText: album.name),
            const SizedBox(height: 4),
            Text(album.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            Text(
                [
                  if (album.artist.isNotEmpty) album.artist,
                  if (album.publishYear.isNotEmpty) album.publishYear,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// 一格歌手：圆头像加名字。点开是歌手页，热歌和他的碟都在那儿。
class _ArtistCard extends StatelessWidget {
  final ArtistInfo artist;
  const _ArtistCard({required this.artist});

  static const _side = 72.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _side + 10,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ArtistPage(artistId: artist.id, seedName: artist.name)),
        ),
        child: Column(
          children: [
            ClipOval(
              child: CoverTile(
                  label: '', imageUrl: artist.pic, size: _side, icon: Icons.person_outline),
            ),
            const SizedBox(height: 5),
            SizedBox(
              width: _side + 10,
              child: Text(artist.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向那一排只有 12 位热门，翻不了几个字。这一行把「按字母整份看」那条路递到眼前，
/// 副标要说清它是每个字母前 100 位 —— 名单是接口给的窗口，不是曲库全量。
class _RosterEntry extends StatelessWidget {
  const _RosterEntry();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const ArtistRosterPage())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(color: AppTheme.pillBg, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Icon(Icons.people_outline, size: 20, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('按字母翻明星名单', style: TextStyle(fontSize: 14)),
                    SizedBox(height: 2),
                    Text('A–Z 加一格「其它」，每格前 100 位 · 进去直接筛名字或别名',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetCategories extends StatefulWidget {
  const _SheetCategories({super.key});

  @override
  State<_SheetCategories> createState() => _SheetCategoriesState();
}

class _SheetCategoriesState extends State<_SheetCategories> {
  /// 三列四行：歌单卡每一行还要占一百多像素，再多就把榜单推得更远；想要下一批，
  /// 手边就有「换一批」。
  static const _pageSize = 12;
  String _category = '推荐';
  List<SheetInfo> _sheets = const [];
  bool _loading = false;
  bool _swapping = false;

  /// 「全部分类」摊开没有：70 个词全常驻的话，歌单本身就被挤到看不见的地方，
  /// 所以它只是一块挑分类用的临时面板，挑中谁就自己收起。
  bool _catsOpen = false;

  /// 「推荐」走个性化接口，认 offset；其余分类走热门榜，认页码。两条都是页游标，
  /// 分开记免得换分类时拿上一次的游标去问下一类。
  int _offset = 0;
  int _page = 1;

  String? _error;

  /// 连点几个分类就是几趟并发请求，回来的先后看网络：只认最后发起的那一趟。
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 父页下拉刷新时叫一声：缓存已经被清掉，重新取一次当前分类。
  void reload() => _load();

  Future<void> _load() async {
    final gen = ++_loadGen;
    final cat = _category;
    setState(() {
      _loading = true;
      _error = null;
      _offset = 0;
      _page = 1;
    });
    try {
      final lib = BuiltinLibrary.instance;
      final list = cat == '推荐'
          ? await lib.recommendedSheets(limit: _pageSize)
          : await lib.sheets('wy', cat, limit: _pageSize);
      if (mounted && gen == _loadGen) setState(() => _sheets = list);
    } catch (e) {
      if (mounted && gen == _loadGen) {
        // 同一条毛病：原来下拉刷新撞上一次网络抖，会把她正在看的这十二张卡抹成一句
        // 报错。留着旧的，只在上面补一行「这是上次那批」。
        setState(() => _error = humanizeError(e));
      }
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  /// 换到下一批：「推荐」把 offset 往后挪一批，其余分类把页码加一。
  /// 2026-10-28 实测 `/api/playlist/list` 的 offset 是真的在翻页（华语连打
  /// 0/12/24 三页，12 首一组基本不重样），所以这一颗按钮不再只属于「推荐」。
  /// 问的张数一直按 [_pageSize]，跟着实际拿到的条数走会让下一页的窗口错位。
  Future<void> _swap() async {
    if (_swapping || _sheets.isEmpty) return;
    final gen = _loadGen;
    final cat = _category;
    final lib = BuiltinLibrary.instance;
    setState(() => _swapping = true);
    try {
      final List<SheetInfo> list;
      final int used;
      if (cat == '推荐') {
        final next = _offset + _pageSize;
        var got = await lib.recommendedSheets(limit: _pageSize, offset: next);
        var at = next;
        if (got.isEmpty) {
          // 挪过头了（个性化接口给的就这么多）：回到开头那一批，别让她点了个没动静。
          got = await lib.recommendedSheets(limit: _pageSize, offset: 0);
          at = 0;
        }
        list = got;
        used = at;
      } else {
        final next = _page + 1;
        var got = await lib.sheets('wy', cat, page: next, limit: _pageSize);
        var at = next;
        if (got.isEmpty) {
          got = await lib.sheets('wy', cat, page: 1, limit: _pageSize);
          at = 1;
        }
        list = got;
        used = at;
      }
      // 等的这一会儿她可能已经切了分类：那这批就不是这一类的答案了。
      if (!mounted || gen != _loadGen) return;
      if (list.isNotEmpty) {
        if (cat == '推荐') {
          _offset = used;
        } else {
          _page = used;
        }
        setState(() => _sheets = list);
      }
    } catch (e) {
      // 换失败保持原样，但要吭一声，不然点了没动静看着像按钮坏了。
      if (mounted) toast(context, '这批没换出来：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
  }

  /// 挑一个分类。面板是临时摊开的那一块，选完就收起——不然 70 颗胶囊继续压在
  /// 歌单上面，下一屏还是看不到歌单。
  void _pick(String c) {
    if (c == _category) {
      if (_catsOpen) setState(() => _catsOpen = false);
      return;
    }
    setState(() {
      _category = c;
      _catsOpen = false;
      _sheets = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final quick = BuiltinLibrary.instance.sheetCategories;
    final itemW = sheetCardWidth(MediaQuery.sizeOf(context).width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('歌单分类',
            actionText: _sheets.isEmpty ? null : (_swapping ? '正在换…' : '换一批'),
            onAction: _swapping || _sheets.isEmpty ? null : _swap),
        SizedBox(
          height: 34,
          child: MouseDragScroll(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: quick.length + 1,
              itemBuilder: (context, i) {
                if (i == quick.length) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: _ExpandChip(open: _catsOpen, onTap: () => setState(() => _catsOpen = !_catsOpen)),
                  );
                }
                final c = quick[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _CatChip(name: c, active: c == _category, onTap: () => _pick(c)),
                );
              },
            ),
          ),
        ),
        if (_catsOpen) _CategoryPanel(current: _category, onPick: _pick),
        const SizedBox(height: 10),
        if (_loading && _sheets.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Center(child: CircularProgressIndicator()))
        else ...[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    // 上一批还在屏上就不能说「没拉到」：那十二张是上一次的，
                    // 得让她知道现在看到的是什么时候的东西。
                    child: Text(
                        _sheets.isEmpty
                            ? '歌单没拉到：$_error'
                            : '这批歌单是上次那批：$_error',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
                  ),
                  TextButton(onPressed: _load, child: const Text('重试', style: TextStyle(fontSize: 13))),
                ],
              ),
            ),
          if (_sheets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 12,
                children: [
                  for (final s in _sheets)
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => SheetDetailPage(sheet: s)),
                      ),
                      // 长按即收藏，不用先进详情页再点右上角。
                      onLongPress: () => toggleSheetFavorite(context, s),
                      child: CoverCard(sheet: s, width: itemW),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// 横向分类行末尾那一颗：摊开/收起「全部分类」。它不是分类，所以不参与选中态。
class _ExpandChip extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _ExpandChip({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(open ? '收起分类' : '全部分类',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            Icon(open ? Icons.expand_less : Icons.expand_more, size: 15, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// 「全部分类」摊开的那一块。词表是端内带的（抄的是官方分类树 `/api/playlist/catalogue`
/// 给的那 70 个词，但每个词都还得自己打一次 `/api/playlist/list` 验过——未知分类网易云
/// 不报错，直接回一张兜底歌单，看不出来）；挑中谁由外面把面板收起。
class _CategoryPanel extends StatelessWidget {
  final String current;
  final ValueChanged<String> onPick;
  const _CategoryPanel({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final g in BuiltinLibrary.instance.sheetCategoryGroups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Text(g.title, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in g.names)
                  _CatChip(name: c, active: c == current, onTap: () => onPick(c)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CatChip extends StatelessWidget {
  final String name;
  final bool active;
  final VoidCallback onTap;
  const _CatChip({required this.name, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 不能用 Container(alignment:)：alignment 会让 Container 撑满给到的宽度，
        // 而「全部分类」那块面板就是把这枚胶囊摆进 Wrap 里的 —— 撑满之后一行只放得下
        // 一颗，70 个词竖着排成两屏多大按钮。Row(mainAxisSize: min) 两边都收着长，
        // 又被横向那一排钉在 34 高里时照样把字居中。
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : AppTheme.sheetBg,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name,
                style: TextStyle(
                    fontSize: 12.5,
                    color: active ? Colors.white : AppTheme.textPrimary,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

/// 一组榜单一行，横着滑。六十来个榜铺成三列宫格是二十多行、四屏多的地方，横向一行
/// 就把一整组收进一格；名字写在封面上，简介和来源那一行让位给密度。
class _RankStrip extends StatelessWidget {
  final List<RankInfo> ranks;
  final ValueChanged<RankInfo> onTap;
  const _RankStrip({required this.ranks, required this.onTap});

  static const _side = 84.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _side,
      child: MouseDragScroll(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: ranks.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, i) => InkWell(
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            onTap: () => onTap(ranks[i]),
            child: CoverTile(
              label: ranks[i].name,
              seedText: ranks[i].name,
              imageUrl: ranks[i].img,
              size: _side,
              icon: Icons.leaderboard,
            ),
          ),
        ),
      ),
    );
  }
}
