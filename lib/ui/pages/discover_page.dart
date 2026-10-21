import 'package:flutter/material.dart';

import '../../models/results.dart';
import '../../util/humanize.dart';
import '../rank_groups.dart';
import '../widgets.dart';
import 'builtin_library.dart';
import 'rank_detail_page.dart';
import 'sheet_detail_page.dart';
import '../theme.dart';

/// 发现 — playlist categories plus the full ranking list.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> implements ScrollToTop {
  static const _rankSources = ['wy', 'kw'];
  final ScrollController _scroll = ScrollController();
  // 下拉刷新时歌单分类那一块也要跟着重取，不然它还拿着刚才被清掉的旧数据。
  final _sheetBlockKey = GlobalKey<_SheetCategoriesState>();
  List<RankInfo> _ranks = const [];
  String _rankSource = 'wy';
  bool _loading = false;
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
          const SliverToBoxAdapter(child: SectionHeader('榜单')),
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
                padding: const EdgeInsets.all(16),
                child: Text('榜单加载失败：$_error', style: const TextStyle(color: AppTheme.primary, fontSize: 12)),
              ),
            ),
          if (_loading && _ranks.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))),
          for (final g in groups) ...[
            SliverToBoxAdapter(child: SectionHeader(g.title)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.78,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _RankCard(rank: g.ranks[i], onTap: _openRank),
                  childCount: g.ranks.length,
                ),
              ),
            ),
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
  String _category = '推荐';
  List<SheetInfo> _sheets = const [];
  bool _loading = false;
  bool _swapping = false;
  int _offset = 0;
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
    });
    try {
      final lib = BuiltinLibrary.instance;
      final list = cat == '推荐'
          ? await lib.recommendedSheets(limit: 18)
          : await lib.sheets('wy', cat);
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

  /// 「推荐」分类走个性化接口，认 offset，所以能换一批；其他分类是热门榜，
  /// 换的只是顺序，就没有放这个按钮。
  Future<void> _swap() async {
    if (_swapping || _sheets.isEmpty) return;
    final gen = _loadGen;
    final lib = BuiltinLibrary.instance;
    final size = _sheets.length;
    setState(() => _swapping = true);
    try {
      final next = _offset + size;
      var list = await lib.recommendedSheets(limit: size, offset: next);
      var used = next;
      if (list.isEmpty) {
        list = await lib.recommendedSheets(limit: size, offset: 0);
        used = 0;
      }
      // 等的这一会儿她可能已经切了分类：那这批就不是这一类的答案了。
      if (!mounted || gen != _loadGen) return;
      if (list.isNotEmpty) {
        _offset = used;
        setState(() => _sheets = list);
      }
    } catch (e) {
      // 换失败保持原样，但要吭一声，不然点了没动静看着像按钮坏了。
      if (mounted) toast(context, '这批没换出来：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _swapping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('歌单分类',
            actionText: _category == '推荐' ? (_swapping ? '正在换…' : '换一批') : null,
            onAction: _category == '推荐' && !_swapping ? _swap : null),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: BuiltinLibrary.instance.sheetCategories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final c = BuiltinLibrary.instance.sheetCategories[i];
              final active = c == _category;
              return GestureDetector(
                onTap: () {
                  if (active) return;
                  setState(() => _category = c);
                  _load();
                },
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: active ? AppTheme.primary : AppTheme.sheetBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(c,
                      style: TextStyle(
                          fontSize: 13,
                          color: active ? Colors.white : AppTheme.textPrimary,
                          fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
                ),
              );
            },
          ),
        ),
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
          Wrap(
            spacing: 12,
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
                  child: CoverCard(sheet: s),
                ),
            ],
          ),
      ],
    );
  }
}

class _RankCard extends StatelessWidget {
  final RankInfo rank;
  final ValueChanged<RankInfo> onTap;
  const _RankCard({required this.rank, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      onTap: () => onTap(rank),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.sheetBg,
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(rank.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CoverTile(
                      label: '', seedText: rank.name, imageUrl: rank.img, size: 34, icon: Icons.leaderboard),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // 酷我那份榜是常量表，没有一句话说明；写来源也比写「KW」好认。
                    rank.desc?.isNotEmpty == true ? rank.desc! : sourceLabel(rank.source),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
