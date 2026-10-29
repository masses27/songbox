import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builtin_library.dart';

class RankDetailPage extends StatefulWidget {
  final String title;
  final Future<SearchResult> Function(int page) load;

  const RankDetailPage({
    super.key,
    required this.title,
    required this.load,
  });

  @override
  State<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<RankDetailPage> {
  final _scroll = ScrollController();
  List<Song> _songs = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String? _moreError;

  /// 页码自己记：每页多少首由数据层决定（网易云 50、酷我 30），按已加载条数
  /// 反推页码会跳页或重复。
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 320) _loadMore();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      // 榜已经刷出来了就别把整页换成转圈，下拉刷新不该先让人空看一眼。
      _loading = _songs.isEmpty;
      _error = null;
      _moreError = null;
    });
    try {
      // 下拉刷新要绕过 5 分钟目录缓存，不然刷出来的还是同一条榜单。
      if (refresh) BuiltinLibrary.instance.invalidateCatalog();
      final res = await widget.load(1);
      if (!mounted) return;
      setState(() {
        _page = 1;
        _songs = res.list;
        _hasMore = res.list.isNotEmpty && _page < res.allPage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
      // 旧榜单还在屏幕上时错误块不出现（它只占空列表那一格），不吭一声就是「点了没反应」。
      if (_songs.isNotEmpty) toast(context, '这个榜没刷新下来：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final next = _page + 1;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final res = await widget.load(next);
      if (!mounted) return;
      if (res.list.isEmpty) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
        return;
      }
      final known = _songs.map((s) => '${s.source}:${s.songmid}').toSet();
      setState(() {
        _page = next;
        _songs = [..._songs, ...res.list.where((s) => !known.contains('${s.source}:${s.songmid}'))];
        _hasMore = _page < res.allPage;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 别静默终止：留着 footer 上的重试，用户才知道是网络抖了一下而不是榜单只有这么多。
      setState(() {
        _moreError = humanizeError(e);
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 桌面上这一颗是这一页唯一的刷新入口：鼠标拖不动下拉刷新。
          DesktopRefreshButton(onRefresh: () => _load(refresh: true), busy: _loading),
          if (_songs.isNotEmpty) ...[
            IconButton(
              tooltip: '把这一榜收进收藏',
              icon: const Icon(Icons.favorite),
              onPressed: () => collectAllFavorites(context, _songs),
            ),
            IconButton(
              tooltip: '播放整个列表',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => context.read<PlayerService>().playList(_songs, 0),
            ),
          ],
        ],
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: _loading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 160), Center(child: CircularProgressIndicator())],
              )
            : _error != null && _songs.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      EmptyState(message: _error!, actionText: '重试', onAction: () => _load(refresh: true)),
                    ],
                  )
                : _songs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [EmptyState(message: '这个榜单暂时没有内容')],
                      )
                    : Column(
                        children: [
                          VipScanBar(songs: _songs),
                          Expanded(
                            child: ListView.separated(
                              controller: _scroll,
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: _songs.length + 1,
                              separatorBuilder: (_, _) =>
                                  Divider(height: 1, color: AppTheme.divider),
                              itemBuilder: (context, i) {
                                if (i == _songs.length) return _footer();
                                final s = _songs[i];
                                return SongListRow(
                                  song: s,
                                  number: i + 1,
                                  siblings: _songs,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
      ),
    );
  }

  /// 列表尾巴：加载中 / 失败可重试 / 已全部加载完。
  Widget _footer() {
    if (_moreError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('后面还有，但没加载出来', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            TextButton(onPressed: _loadMore, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_hasMore) {
      // 滑到底自己会接下一页，可榜单短到不足一屏时那一划永远不会发生 ——
      // 原来这里只剩一根停不下来的圈。转圈只留给真在加载的那几秒。
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.expand_more, size: 18),
            label: Text('接着加载后面那些', style: const TextStyle(fontSize: 12)),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
      child: Center(
        child: Text('已经到底 · 共 ${_songs.length} 首',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ),
    );
  }
}
