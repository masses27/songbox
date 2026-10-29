import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../rank_groups.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builtin_library.dart';
import 'daily_page.dart';
import 'rank_detail_page.dart';
import 'search_page.dart';
import 'sheet_detail_page.dart';

/// 首页 — NetEase-style landing: recommendations, new songs, rankings.
class HomePage extends StatefulWidget {
  /// 跳到指定的底部 tab（0 首页 / 1 发现 / 2 我的），宫格入口用。
  final ValueChanged<int> onOpenTab;
  const HomePage({super.key, required this.onOpenTab});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> implements ScrollToTop {
  final ScrollController _scroll = ScrollController();
  List<RankInfo> _ranks = const [];
  List<SheetInfo> _sheets = const [];
  List<Song> _newSongs = const [];
  bool _loading = false;
  bool _swapping = false;
  int _sheetsOffset = 0;

  /// 正在拉歌的那个榜单 id：播放键按下去要转圈，不然慢网下看着像没反应。
  String? _rankPlaying;
  String? _error;

  /// 三块里坏了哪几块、各自为什么。原来只留第一条错误（`_error ??=`），
  /// 两块一起坏的时候那句「首页有一部分没拉到」看不出是几部分、是哪部分。
  List<({String block, String why})> _failedBlocks = const [];

  @override
  void initState() {
    super.initState();
    _load();
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

  /// 三块内容一块都没落下来：只有这时候才该用整页空态挡人。
  /// 坏一块的情况下另外两块照样在屏幕上，错误得写成一行挂在中间，不然她看不见。
  bool get _nothingOnScreen => _ranks.isEmpty && _sheets.isEmpty && _newSongs.isEmpty;

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = _ranks.isEmpty && _sheets.isEmpty;
      _error = null;
      _failedBlocks = const [];
      if (refresh) _sheetsOffset = 0;
    });
    final lib = BuiltinLibrary.instance;
    if (refresh) lib.invalidateCatalog();
    final failed = <({String block, String why})>[];
    void note(String block, Object e) {
      _error ??= humanizeError(e);
      failed.add((block: block, why: humanizeError(e)));
    }

    // Each block loads independently so one dead endpoint cannot blank the page.
    // 坏掉的那几块按屏幕上那三个标题记账，她一眼就能对上少了哪一块。
    await Future.wait([
      lib.rankList('wy').then((v) => _ranks = v).catchError((e) {
            note('排行榜', e);
            return const <RankInfo>[];
          }),
      lib.recommendedSheets().then((v) => _sheets = v).catchError((e) {
            note('推荐歌单', e);
            return const <SheetInfo>[];
          }),
      lib.recommendedSongs().then((v) => _newSongs = v).catchError((e) {
            note('推荐新歌曲', e);
            return const <Song>[];
          }),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failedBlocks = failed;
    });
  }

  /// 「换一批」：推荐歌单接口认 offset，往后挪 12 张就是新的一批。
  /// 挪到头会拿回空列表，那就退回去，页面保持原样。
  Future<void> _swapSheets() async {
    if (_swapping || _sheets.isEmpty) return;
    final size = _sheets.length;
    final lib = BuiltinLibrary.instance;
    setState(() => _swapping = true);
    try {
      final next = _sheetsOffset + size;
      var list = await lib.recommendedSheets(limit: size, offset: next);
      var used = next;
      if (list.isEmpty) {
        // 挪到头了，绕回第一批（这一批已经在缓存里，不会再发请求）。
        list = await lib.recommendedSheets(limit: size, offset: 0);
        used = 0;
      }
      if (!mounted) return;
      if (list.isNotEmpty) {
        _sheetsOffset = used;
        setState(() => _sheets = list);
      }
    } catch (e) {
      // 换失败原来那批还在，但要吭一声，不然点了没动静看着像按钮坏了。
      if (mounted) toast(context, '这批没换出来：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
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

  void _openSheet(SheetInfo sheet) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SheetDetailPage(sheet: sheet),
      ),
    );
  }

  /// 榜单行右侧的播放键：一下就能听这个榜，不用先进详情页再找「播放全部」。
  /// 队列起在底部播放条上，所以这里刻意不跳播放页。
  Future<void> _playRank(RankInfo rank) async {
    if (_rankPlaying != null) return;
    setState(() => _rankPlaying = rank.id);
    try {
      final res = await BuiltinLibrary.instance.rankSongs(rank.source, rank.id);
      if (!mounted) return;
      if (res.list.isEmpty) {
        toast(context, '这个榜暂时没取到歌');
        return;
      }
      context.read<PlayerService>().playList(res.list, 0);
    } catch (e) {
      if (mounted) toast(context, '这个榜没打开：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _rankPlaying = null);
    }
  }

  /// Plays in place: no page push, the mini bar at the bottom takes over.
  void _play(Song song, List<Song> all) {
    context.read<PlayerService>().playList(all, all.indexOf(song));
  }

  @override
  Widget build(BuildContext context) {
    final banner = _sheets.take(5).toList();
    final recommend = _sheets;
    final ranks = homeRanks(_ranks);
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: CustomScrollView(
        controller: _scroll,
        // 内容不足一屏时也要能下拉刷新，否则 RefreshIndicator 不会响应。
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    const Text('听歌小窝', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                    const SizedBox(width: 10),
                    Expanded(child: NetEaseSearchBar(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchPage())))),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 2)),
          SliverToBoxAdapter(
            child: _QuickGrid(
              onOpenTab: widget.onOpenTab,
              onDaily: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DailyPage())),
            ),
          ),
          if (_error != null && _nothingOnScreen)
            SliverToBoxAdapter(
              child: EmptyState(
                message: '推荐内容没拉到：$_error',
                actionText: '重新加载',
                onAction: () => _load(refresh: true),
              ),
            ),
          if (_failedBlocks.isNotEmpty && !_nothingOnScreen)
            // 三块各自加载，坏一块时另外两块照样在屏幕上 —— 原来那种情况下那句错误
            // 一点地方都没有，看上去就像「今天的推荐就这么点」，她不会想到去下拉。
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 坏几块写几行：两块一起坏的时候，只显示第一条错误会把
                          // 另一块的问题盖掉。
                          for (final f in _failedBlocks)
                            Text('${f.block}没拉到：${f.why}',
                                style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
                        ],
                      ),
                    ),
                    TextButton(
                        onPressed: () => _load(refresh: true),
                        child: const Text('重试', style: TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
          if (_loading && _ranks.isEmpty && _sheets.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator())))
          else ...[
            if (banner.isNotEmpty) SliverToBoxAdapter(child: HomeBanner(sheets: banner, onTap: _openSheet)),
            if (_newSongs.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('推荐新歌曲')),
              SliverToBoxAdapter(child: _SongCarousel(songs: _newSongs, onTap: _play)),
            ],
            if (recommend.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SectionHeader('推荐歌单',
                    actionText: _swapping ? '正在换…' : '换一批', onAction: _swapping ? null : _swapSheets),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  // 封面 108 + 两行标题 + 一行播放量，留够余量，窄屏机上不会溢出报错。
                  height: 165,
                  child: MouseDragScroll(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: recommend.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, i) => GestureDetector(
                        onTap: () => _openSheet(recommend[i]),
                        // 长按即收藏，和发现页的歌单卡一致。
                        onLongPress: () => toggleSheetFavorite(context, recommend[i]),
                        child: CoverCard(sheet: recommend[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_ranks.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SectionHeader('排行榜',
                    actionText: '全部榜单', onAction: () => widget.onOpenTab(1)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _RankRow(
                      rank: ranks[i],
                      onTap: () => _openRank(ranks[i]),
                      onPlay: () => _playRank(ranks[i]),
                      playing: _rankPlaying == ranks[i].id,
                    ),
                    childCount: ranks.length,
                  ),
                ),
              ),
            ] else
              const SliverToBoxAdapter(child: SizedBox(height: 30)),
          ],
        ],
      ),
    );
  }
}

/// 首页顶部那排轮播卡。整张卡认点击（进歌单）、长按收藏；桌面版还要能拖、
/// 能点下面的指示点、能按左右箭头。
///
/// 桌面版原来这三样全不通：Flutter 默认不把鼠标算进 scrollable 的拖拽设备
/// （`ScrollBehavior.dragDevices`），滚轮又只喂给自己那一根轴，所以横向轮播
/// 在 Windows 上一步都挪不动；指示点更是只画了个色块、没接命中。
class HomeBanner extends StatefulWidget {
  final List<SheetInfo> sheets;
  final ValueChanged<SheetInfo> onTap;

  /// 左右那对箭头只在桌面版出现：手机上这一格本来就窄，再压两个圆钮进去，
  /// 卡上的字就没地方放了。单测把它显式打开，免得换台机器跑就测不到这条。
  final bool arrows;
  HomeBanner({super.key, required this.sheets, required this.onTap, bool? arrows})
      : arrows = arrows ?? Platform.isWindows;

  @override
  State<HomeBanner> createState() => _HomeBannerState();
}

class _HomeBannerState extends State<HomeBanner> {
  final _ctrl = PageController(viewportFraction: 0.92);
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 指示点和箭头都走这一条：越界的先挡掉，不然 PageView 会抛。
  void _go(int i) {
    final last = widget.sheets.length - 1;
    if (!_ctrl.hasClients || i < 0 || i > last || i == _page) return;
    setState(() => _page = i);
    _ctrl.animateToPage(i, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.sheets.length;
    return Column(
      children: [
        SizedBox(
          height: 130,
          child: MouseDragScroll(
            child: Stack(
              children: [
                PageView.builder(
                  controller: _ctrl,
                  itemCount: n,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final s = widget.sheets[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      child: GestureDetector(
                        onTap: () => widget.onTap(s),
                        onLongPress: () => toggleSheetFavorite(context, s),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                            child: CoverTile(
                                label: s.name,
                                imageUrl: s.img,
                                size: double.infinity,
                                icon: Icons.campaign),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 拖拽这件事她不一定会去试，箭头是看一眼就知道能动的东西。
                if (n > 1 && widget.arrows) ...[
                  Positioned(
                    left: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _BannerArrow(
                          key: const ValueKey('banner-prev'),
                          icon: Icons.chevron_left,
                          onTap: _page > 0 ? () => _go(_page - 1) : null),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _BannerArrow(
                          key: const ValueKey('banner-next'),
                          icon: Icons.chevron_right,
                          onTap: _page < n - 1 ? () => _go(_page + 1) : null),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < n; i++)
              // 命中区撑到 20 多见方：6 个像素的点，鼠标落不准就等于没接。
              MouseRegion(
                key: ValueKey('banner-dot-$i'),
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _go(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: i == _page ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _page ? AppTheme.primary : AppTheme.textSecondary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 轮播左右那颗圆箭头：这一头走到头就置灰、不接点击。
class _BannerArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _BannerArrow({super.key, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: on ? .42 : .18),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: on ? .95 : .45)),
        ),
      ),
    );
  }
}

class _SongCarousel extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song, List<Song>) onTap;
  const _SongCarousel({required this.songs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final items = songs.take(12).toList();
    return SizedBox(
      height: 132,
      child: MouseDragScroll(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) =>
              SongCard(song: items[i], batch: items, onTap: onTap),
        ),
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  final RankInfo rank;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final bool playing;
  const _RankRow(
      {required this.rank, required this.onTap, required this.onPlay, required this.playing});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            CoverTile(label: '', seedText: rank.name, imageUrl: rank.img, size: 56, icon: Icons.leaderboard),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rank.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(rank.desc?.isNotEmpty == true ? rank.desc! : '${sourceLabel(rank.source)} · 榜单',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            // 整行点进去是榜单详情，只有这个键是「直接开听」。
            IconButton(
              onPressed: playing ? null : onPlay,
              tooltip: '播放这个榜',
              visualDensity: VisualDensity.compact,
              iconSize: 26,
              icon: playing
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, color: AppTheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首屏宫格：把每天真正会点这三件事摆在搜索框下面，不用先翻推荐。
class _QuickGrid extends StatelessWidget {
  final ValueChanged<int> onOpenTab;
  final VoidCallback onDaily;
  const _QuickGrid({required this.onOpenTab, required this.onDaily});

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(icon: Icons.auto_awesome, tint: AppTheme.tile(const Color(0xFFFFF1E0)), label: '今日私荐', onTap: onDaily),
      _Tile(icon: Icons.leaderboard, tint: AppTheme.tile(const Color(0xFFFFE7E7)), label: '排行榜', onTap: () => onOpenTab(1)),
      _Tile(icon: Icons.favorite_border, tint: AppTheme.tile(const Color(0xFFFCE7EF)), label: '我的收藏', onTap: () => onOpenTab(2)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Row(children: [for (final t in tiles) Expanded(child: t)]),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String label;
  final VoidCallback onTap;
  const _Tile({required this.icon, required this.tint, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: AppTheme.primary, size: 22),
            ),
            const SizedBox(height: 5),
            Text(label, style: TextStyle(fontSize: 11.5, color: AppTheme.textPrimary)),
          ],
        ),
      ),
    );
  }
}
