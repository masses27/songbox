import 'package:flutter/material.dart';

import '../../models/results.dart';
import '../../util/humanize.dart';
import '../rank_groups.dart';
import '../widgets.dart';
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
  static const _rankSources = ['wy', 'kw'];
  final ScrollController _scroll = ScrollController();
  // 下拉刷新时歌单分类那一块也要跟着重取，不然它还拿着刚才被清掉的旧数据。
  final _sheetBlockKey = GlobalKey<_SheetCategoriesState>();
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
                    Text('歌单分类 · 榜单', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
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
                      child: Text('榜单加载失败：$_error',
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

  /// 「全部分类」摊开没有：57 个词全常驻的话，歌单本身就被挤到看不见的地方，
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
        setState(() {
          _error = humanizeError(e);
          _sheets = const [];
        });
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

  /// 挑一个分类。面板是临时摊开的那一块，选完就收起——不然 57 颗胶囊继续压在
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
        if (_catsOpen) _CategoryPanel(current: _category, onPick: _pick),
        const SizedBox(height: 10),
        if (_loading && _sheets.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text('歌单没拉到：$_error',
                      style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
                ),
                TextButton(onPressed: _load, child: const Text('重试', style: TextStyle(fontSize: 13))),
              ],
            ),
          )
        else
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

/// 「全部分类」摊开的那一块。词表是端内带的（网易云那三个分类树接口匿名全 404），
/// 每个词都实测回得到歌单；挑中谁由外面把面板收起。
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
        alignment: Alignment.center,
        // 竖向只留 4：这一排钉在 34 高里，系统字号调大一档的话， padding 给到 6
        // 就要开始啃掉名字的头一笔。
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : AppTheme.sheetBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(name,
            style: TextStyle(
                fontSize: 12.5,
                color: active ? Colors.white : AppTheme.textPrimary,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
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
    );
  }
}
