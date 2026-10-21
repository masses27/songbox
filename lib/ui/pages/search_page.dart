import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../settings/app_settings.dart';
import '../../util/fuzzy_query.dart';
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
  const SearchPage({super.key, this.initialQuery, this.initialKind = 0, this.holdsSong});

  /// 从别处一键跳进来时带来的关键词（点歌手名、找含这首歌的歌单）。
  final String? initialQuery;

  /// 落在哪个 tab：0 单曲、1 歌手、2 专辑、3 歌单。
  final int initialKind;

  /// 从「搜含这首歌的歌单」跳进来时带上：网易云的歌 id（能逐张核对曲目表）；
  /// 空串表示别的曲库没有网易云编号、对不了，只能按名字搜；null = 不是这个入口。
  final String? holdsSong;

  /// 别的页面走这里，别各自抄一遍 Navigator.push。
  static Future<void> open(BuildContext context, String keyword,
          {int kind = 0, String? holdsSong}) =>
      Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                SearchPage(initialQuery: keyword, initialKind: kind, holdsSong: holdsSong)),
      );

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
          return (list: res.list, pages: res.allPage, total: res.total, note: null, checked: 0);
        },
      ),
      _Tab<ArtistInfo>(
        idOf: (a) => a.id,
        label: '位歌手',
        load: (kw, page) async {
          final res = await _library.searchArtists(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total, note: null, checked: 0);
        },
      ),
      _Tab<AlbumInfo>(
        idOf: (a) => a.id,
        label: '张专辑',
        load: (kw, page) async {
          final res = await _library.searchAlbums(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total, note: null, checked: 0);
        },
      ),
      _Tab<SheetInfo>(
        idOf: (s) => s.id,
        label: '个歌单',
        load: (kw, page) async {
          final hold = widget.holdsSong;
          // 只在框里还是跳进来那首歌的名字时才对曲目表：她把词改掉之后，手里
          // 这个 id 跟搜索词已经没关系了。
          if (hold != null && page == 1 && kw == normalizeKeyword(widget.initialQuery ?? '')) {
            // 名字里带着这首歌不算数：逐张核对过曲目表才交出去。核对一张就是
            // 一次请求，所以只核首批。
            if (hold.isEmpty) {
              // 从 QQ、酷我那边点进来的：没有网易云编号，对不了曲目表，
              // 那就只能按名字搜，但得说清这一栏只是名字像。
              final res = await _library.searchSheets(kw, page: 1);
              return (
                list: res.list,
                pages: _pages(res.total),
                total: res.total,
                checked: 0,
                note: '这些歌单只是名字里带着这首歌（非网易云的歌对不了曲目表）'
              );
            }
            final res = await _library.sheetsHolding(kw, hold);
            return (
              list: res.list,
              pages: 1,
              total: res.list.length,
              checked: res.checked,
              note: res.verified ? '下面每张都核对过曲目表，里面真有这首歌' : '这些只是名字里带着这首歌，曲目表里没能确认'
            );
          }
          final res = await _library.searchSheets(kw, page: page);
          return (list: res.list, pages: _pages(res.total), total: res.total, note: null, checked: 0);
        },
      ),
    ];
    for (final tab in _tabs) {
      tab.scroll.addListener(() => _onScroll(tab));
    }
    _kind = widget.initialKind.clamp(0, _kinds.length - 1);
    _tabCtrl = TabController(
        vsync: this, length: _kinds.length, initialIndex: _kind)
      ..addListener(_onTabChanged);
    final kw = widget.initialQuery?.trim() ?? '';
    // 先塞词、后挂监听：带着关键词跳进来不该再排一次搜索联想，
    // 那一发回来会把刚要看的结果页换成联想列表。
    if (kw.isNotEmpty) _ctrl.text = kw;
    _ctrl.addListener(_onTextChanged);
    unawaited(_loadHot());
    if (kw.isEmpty) return;
    // 等一帧再查：_search 里要 setState，而 initState 里 setState 是要报错的。
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
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
    // 联想也按收拾过的词问：全角那个斜杠在她手里就是分隔符，整串递给接口一样搜不出东西。
    final kw = normalizeKeyword(_ctrl.text);
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
      if (!mounted || normalizeKeyword(_ctrl.text) != kw) return;
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
    final kw = normalizeKeyword(_ctrl.text);
    if (kw.isEmpty) return;
    // 收拾过的词写回框里 —— 她看到的就是发出去搜的那个。这一句会顺手排一次
    // 联想，所以紧接着的那次 cancel 不能省。
    if (kw != _ctrl.text) _ctrl.text = kw;
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
    final kw = normalizeKeyword(_ctrl.text);
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
        // 空结果不等于「真没有」：把还能试的写法备好，界面在空态下面递给她点。
        target.keyword = kw;
        target.alternatives = target.items.isEmpty ? relaxations(kw) : const [];
        if (!loadMore) {
          target.note = res.note;
          target.checked = res.checked;
        }
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
                  // 带着词跳进来是来看结果的，不是来打字的：键盘别先弹出来占半屏。
                  autofocus: widget.initialQuery?.trim().isNotEmpty != true,
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
    // 和 _onTextChanged 用同一个算法，否则联想列表永远对不上当前输入、不显示。
    final kw = normalizeKeyword(_ctrl.text);
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
      return ListView(
        children: [
          EmptyState(
              message: tab.alternatives.isEmpty
                  ? '没搜到「${tab.keyword}」，换个关键词再试'
                  : '没搜到「${tab.keyword}」\n试试下面这些写法'),
          if (tab.alternatives.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final alt in tab.alternatives)
                    ActionChip(
                      label: Text(alt, style: const TextStyle(fontSize: 13)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _useKeyword(alt),
                    ),
                ],
              ),
            ),
        ],
      );
    }
    // 核对过的结果要在上面先说一句「每张都查过曲目表」，不然她以为
    // 这跟普通搜歌单是一回事。
    final head = tab.note == null ? 0 : 1;
    return ListView.separated(
      controller: tab.scroll,
      itemCount: tab.items.length + 1 + head,
      separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.divider),
      itemBuilder: (context, i) {
        if (head == 1) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(tab.note!,
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            );
          }
          i -= 1;
        }
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
    if (tab.checked > 0) {
      // 核对只摊开看了前几张，写「已全部加载」就成了骗人；张数按实际核过的说，
      // 核满 5 张就停的时候它比候选那批小。
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Text('核对了搜到的前 ${tab.checked} 张 · 共 ${tab.items.length} ${tab.label}',
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

  final Future<({List<T> list, int pages, int total, String? note, int checked})> Function(
      String keyword, int page) load;
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

  /// 这一页实际搜出去的那个词，和空结果时还能再试的写法。
  String keyword = '';
  List<String> alternatives = const [];

  /// 结果上面那句说明：只有在「核对过每张歌单」这类筛选后面才非空。
  String? note;

  /// 这一栏背后逐张核对过几张曲目表。0 = 没核对，就是普通分页搜索，底部那句
  /// 「先查了前 N 张」这时候不能说 —— 非网易云那条入口也带说明文字，但它没核过。
  int checked = 0;

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
    keyword = '';
    alternatives = const [];
    note = null;
    checked = 0;
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
