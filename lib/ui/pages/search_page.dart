import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../settings/app_settings.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'builtin_library.dart';
import 'sheet_detail_page.dart';

/// 搜索: one keyword, four result kinds (单曲 / 歌手 / 专辑 / 歌单), each with its
/// own paging — the same shape 网易云 uses.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _library = BuiltinLibrary.instance;
  late final List<_Tab> _tabs;
  late final TabController _tabCtrl;
  String _source = 'wy';
  int _kind = 0;
  Timer? _suggestTimer;
  List<SuggestItem> _suggest = const [];
  String _suggestFor = '';
  List<String> _hot = const [];

  static const _sources = ['wy', 'kw', 'tx'];
  static const _kinds = ['单曲', '歌手', '专辑', '歌单'];

  @override
  void initState() {
    super.initState();
    _tabs = [
      _Tab<Song>(
        idOf: (s) => '${s.source}:${s.songmid}',
        label: '首',
        load: (kw, page) async {
          final res = await _library.search(kw, source: _source, page: page);
          return (list: res.list, pages: res.allPage, total: res.total);
        },
      ),
      _Tab<ArtistInfo>(
        idOf: (a) => a.id,
        label: '位歌手',
        load: (kw, page) async {
          final res = await _library.searchArtists(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total);
        },
      ),
      _Tab<AlbumInfo>(
        idOf: (a) => a.id,
        label: '张专辑',
        load: (kw, page) async {
          final res = await _library.searchAlbums(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total);
        },
      ),
      _Tab<SheetInfo>(
        idOf: (s) => s.id,
        label: '个歌单',
        load: (kw, page) async {
          final res = await _library.searchSheets(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total);
        },
      ),
    ];
    for (final tab in _tabs) {
      tab.scroll.addListener(() => _onScroll(tab));
    }
    _tabCtrl = TabController(vsync: this, length: _kinds.length)..addListener(_onTabChanged);
    _ctrl.addListener(_onTextChanged);
    unawaited(_loadHot());
  }

  Future<void> _loadHot() async {
    try {
      final words = await _library.hotWords();
      if (mounted) setState(() => _hot = words);
    } catch (_) {
      // 热搜拉不到就用历史记录，不值得弹错。
    }
  }

  int _pages(int total) => (total / 30).ceil().clamp(1, 200);

  _Tab get _current => _tabs[_kind];

  void _onTabChanged() {
    if (_kind == _tabCtrl.index) return;
    setState(() {
      _kind = _tabCtrl.index;
      _suggest = const [];
      _suggestFor = '';
    });
    final tab = _current;
    if (!tab.searched && !tab.loading && _ctrl.text.trim().isNotEmpty) {
      _run(tab: tab);
    }
  }

  void _onTextChanged() {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty && mounted && _tabs.any((t) => t.items.isNotEmpty)) {
      setState(_resetAll);
    }
    _suggestTimer?.cancel();
    if (kw.isEmpty || _source != 'wy') {
      if (_suggest.isNotEmpty) setState(() => _suggest = const []);
      return;
    }
    // 打字时不要每个字符发一次请求，停 0.3 秒再查。
    _suggestTimer = Timer(const Duration(milliseconds: 320), () => _fetchSuggest(kw));
  }

  Future<void> _fetchSuggest(String kw) async {
    try {
      final items = await _library.searchSuggest(kw);
      if (!mounted || _ctrl.text.trim() != kw) return;
      setState(() {
        _suggest = items;
        _suggestFor = kw;
      });
    } catch (_) {
      // 联想只是加分项，失败就安静地回到结果页。
      if (mounted) setState(() => _suggest = const []);
    }
  }

  void _useKeyword(String kw) {
    _ctrl.text = kw;
    _ctrl.selection = TextSelection.collapsed(offset: kw.length);
    _search();
  }

  void _resetAll() {
    for (final t in _tabs) {
      t.reset();
    }
  }

  void _onScroll(_Tab tab) {
    if (!tab.canLoadMore || tab.loading) return;
    if (tab.scroll.position.pixels > tab.scroll.position.maxScrollExtent - 300) {
      _run(tab: tab, loadMore: true);
    }
  }

  /// A fresh keyword clears every tab; switching source does the same because
  /// the other库 has no 歌手/专辑/歌单 results.
  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    _suggestTimer?.cancel();
    setState(() {
      _suggest = const [];
      _suggestFor = '';
      _resetAll();
    });
    await _run(tab: _current);
  }

  Future<void> _run({_Tab? tab, bool loadMore = false}) async {
    final target = tab ?? _current;
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) return;
    if (loadMore && !target.canLoadMore) return;
    setState(() {
      target.loading = true;
      target.error = null;
    });
    AppSettings.instance.rememberSearch(kw);
    final next = loadMore ? target.page + 1 : 1;
    try {
      final res = await target.load(kw, next);
      if (!mounted) return;
      setState(() {
        target.addAll(res.list);
        target.page = next;
        target.pages = res.pages;
        target.total = res.total;
        target.searched = true;
        target.moreError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 翻页失败要留在列表底部可见，不然用户以为已经到底了。
      setState(() {
        if (loadMore) {
          target.moreError = humanizeError(e);
        } else {
          target.error = humanizeError(e);
        }
      });
    } finally {
      if (mounted) setState(() => target.loading = false);
    }
  }

  void _pickSource(String s) {
    if (_source == s) return;
    _suggestTimer?.cancel();
    setState(() {
      _source = s;
      _kind = 0;
      _suggest = const [];
      _suggestFor = '';
      _resetAll();
      // 切 TabBar 要放在最后：先动它会让 _onTabChanged 抢在复位之前发一次请求，
      // 和下面这一次撞成两遍同样的搜索。
      _tabCtrl.index = 0;
    });
    if (_ctrl.text.trim().isNotEmpty) _run();
  }

  /// 清空历史给一次撤销：她可能只是不想看见某一个词，误点「清空」就把攒下来的
  /// 全没了。传进来的 list 是设置里那份活的引用，所以要先抄一份再清。
  void _clearHistory(List<String> live) {
    final snap = List<String>.from(live);
    if (snap.isEmpty) return;
    AppSettings.instance.clearSearchHistory();
    toast(context, '已清空搜索历史', actionLabel: '撤销', onAction: () {
      AppSettings.instance.restoreSearchHistory(snap);
    });
  }

  @override
  void dispose() {
    _suggestTimer?.cancel();
    for (final t in _tabs) {
      t.scroll.dispose();
    }
    _tabCtrl.dispose();
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AppSettings>().searchHistory;
    final hasQuery = _current.searched || _current.items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _ctrl,
                builder: (context, v, _) => TextField(
                  controller: _ctrl,
                  autofocus: true,
                  onSubmitted: (_) => _search(),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索歌曲、歌手、专辑、歌单',
                    border: InputBorder.none,
                    isDense: true,
                    // 打了一长串想重来时，退格按十下不如一个 ×。
                    suffixIcon: v.text.isEmpty
                        ? null
                        : IconButton(
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            tooltip: '清空',
                            icon: Icon(Icons.close, color: AppTheme.textSecondary),
                            onPressed: () => _ctrl.clear(),
                          ),
                  ),
                ),
              ),
            ),
            // 正在查的时候按下去也只是排第二次队，灰掉更像在忙。
            IconButton(onPressed: _current.loading ? null : _search, icon: const Icon(Icons.search)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(_source == 'wy' ? 80 : 42),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  children: [
                    for (final s in _sources)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(sourceLabel(s)),
                          selected: _source == s,
                          selectedColor: AppTheme.primary.withValues(alpha: .15),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: _source == s ? AppTheme.primary : AppTheme.textSecondary,
                          ),
                          onSelected: (_) => _pickSource(s),
                        ),
                      ),
                    if (hasQuery && _current.items.isNotEmpty)
                      Text(_current.countText, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              if (_source == 'wy')
                TabBar(
                  controller: _tabCtrl,
                  tabs: [for (final k in _kinds) Tab(text: k)],
                  isScrollable: false,
                  indicatorColor: AppTheme.primary,
                  indicatorWeight: 3,
                  labelColor: AppTheme.primary,
                  unselectedLabelColor: AppTheme.textSecondary,
                  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: _body(history),
    );
  }

  Widget _body(List<String> history) {
    final kw = _ctrl.text.trim();
    if (_suggest.isNotEmpty && _suggestFor == kw && kw.isNotEmpty) {
      return _SuggestList(items: _suggest, onPick: _useKeyword);
    }
    if (kw.isEmpty && !_current.searched) {
      return _HistoryList(
        history: history,
        hot: _hot,
        onPick: _useKeyword,
        onClear: () => _clearHistory(history),
      );
    }
    switch (_kind) {
      case 1:
        return _list<ArtistInfo>(_current, _artistTile);
      case 2:
        return _list<AlbumInfo>(_current, _albumTile);
      case 3:
        return _list<SheetInfo>(_current, _sheetTile);
      default:
        return _list<Song>(_current, _songTile);
    }
  }

  Widget _list<T>(_Tab tab, Widget Function(BuildContext, T) tile) {
    if (tab.loading && tab.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.error != null && tab.items.isEmpty) {
      return ListView(
        children: [
          EmptyState(message: '${tab.error}', icon: Icons.cloud_off, actionText: '重试', onAction: _search),
        ],
      );
    }
    if (tab.items.isEmpty) {
      return ListView(children: const [EmptyState(message: '没搜到结果，换个关键词试试')]);
    }
    return ListView.separated(
      controller: tab.scroll,
      itemCount: tab.items.length + 1,
      separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.divider),
      itemBuilder: (context, i) {
        if (i >= tab.items.length) return _footer(tab);
        return tile(context, tab.items[i] as T);
      },
    );
  }

  Widget _footer(_Tab tab) {
    if (tab.loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (tab.moreError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          children: [
            Text('后面还有，但没加载出来', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            TextButton(onPressed: () => _run(tab: tab, loadMore: true), child: const Text('重试', style: TextStyle(fontSize: 13))),
          ],
        ),
      );
    }
    if (tab.canLoadMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Text('继续下滑加载第 ${tab.page + 1} 页',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      child: Text('已全部加载 · 共 ${tab.items.length} ${tab.label}',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    );
  }

  Widget _songTile(BuildContext context, Song s) => SongListRow(
        song: s,
        siblings: _tabs[0].items.cast<Song>(),
        active: context.select<PlayerService, bool>((p) => p.isCurrent(s)),
      );

  Widget _artistTile(BuildContext context, ArtistInfo a) {
    final meta = [
      if (a.alias.isNotEmpty) a.alias,
      if (a.musicSize > 0) '${a.musicSize} 首',
    ].join(' · ');
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: ClipOval(
        child: CoverTile(label: '', imageUrl: a.pic, size: 46, icon: Icons.person_outline),
      ),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
      subtitle: meta.isEmpty
          ? null
          : Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      trailing: Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => ArtistPage(artistId: a.id, seedName: a.name))),
    );
  }

  Widget _albumTile(BuildContext context, AlbumInfo a) {
    final meta = [
      if (a.artist.isNotEmpty) a.artist,
      if (a.publishYear.isNotEmpty) a.publishYear,
      if (a.size > 0) '${a.size} 首',
    ].join(' · ');
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: CoverTile(label: '', imageUrl: a.pic, size: 46, icon: Icons.album_outlined),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
      subtitle: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      trailing: Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => AlbumPage(albumId: a.id, seedName: a.name))),
    );
  }

  Widget _sheetTile(BuildContext context, SheetInfo s) {
    final desc = s.desc ?? '';
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: CoverTile(label: '', imageUrl: s.img, size: 46, icon: Icons.queue_music),
      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
      subtitle: desc.isEmpty
          ? null
          : Text(desc, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      trailing: Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SheetDetailPage(sheet: s))),
      // 搜到的歌单顺手长按收进「我的」，不用先点进详情页。
      onLongPress: () => toggleSheetFavorite(context, s),
    );
  }
}

/// Paging + error state for one search tab.
class _Tab<T> {
  _Tab({required this.load, required this.idOf, required this.label});

  final Future<({List<T> list, int pages, int total})> Function(String keyword, int page) load;
  final String Function(T item) idOf;
  final String label;

  final ScrollController scroll = ScrollController();
  final List<T> items = [];
  final Set<String> _seen = {};
  int page = 0;
  int pages = 1;
  int total = 0;
  bool loading = false;
  bool searched = false;
  String? error;
  String? moreError;

  bool get canLoadMore => searched && page < pages && items.isNotEmpty;

  /// 接口报的总数比已经取回的多时要说清「已加载 / 共」，只写总数会让人以为
  /// 往下滑还能刷出一样的量。
  String get countText =>
      total > items.length ? '已加载 ${items.length} / 共 $total $label' : '共 ${items.length} $label';

  void addAll(List<T> incoming) {
    for (final item in incoming) {
      if (_seen.add(idOf(item))) items.add(item);
    }
  }

  void reset() {
    items.clear();
    _seen.clear();
    page = 0;
    pages = 1;
    total = 0;
    searched = false;
    loading = false;
    error = null;
    moreError = null;
  }
}

/// 输入时的联想下拉：点一下就直接搜这个词。
class _SuggestList extends StatelessWidget {
  final List<SuggestItem> items;
  final ValueChanged<String> onPick;
  const _SuggestList({required this.items, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.divider),
      itemBuilder: (context, i) {
        final s = items[i];
        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          leading: Icon(Icons.north_west, size: 18, color: AppTheme.textSecondary),
          title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
          subtitle: Text(s.hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          onTap: () => onPick(s.text),
        );
      },
    );
  }
}

class _HistoryList extends StatelessWidget {
  final List<String> history;
  final List<String> hot;
  final ValueChanged<String> onPick;
  final VoidCallback onClear;
  const _HistoryList({required this.history, required this.hot, required this.onPick, required this.onClear});

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty && hot.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        message: '输入关键词开始搜索\n网易云、QQ 的歌可以直接播放，不用登录任何账号',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        if (history.isNotEmpty) ...[
          Row(
            children: [
              const Text('搜索历史', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(onPressed: onClear, child: const Text('清空', style: TextStyle(fontSize: 12))),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kw in history)
                InputChip(
                  label: Text(kw, style: const TextStyle(fontSize: 13)),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  onPressed: () => onPick(kw),
                  onDeleted: () => AppSettings.instance.forgetSearch(kw),
                  deleteIcon: const Icon(Icons.close, size: 14),
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        if (hot.isNotEmpty) ...[
          const Text('热门搜索', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (var i = 0; i < hot.length; i++)
            InkWell(
              onTap: () => onPick(hot[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text('${i + 1}',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: i < 3 ? AppTheme.primary : AppTheme.textSecondary)),
                    ),
                    Expanded(child: Text(hot[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
        ],
        Text('提示：点历史词直接搜索，长按小叉单独删除',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ],
    );
  }
}
