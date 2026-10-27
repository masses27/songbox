import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../library/library_store.dart';
import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builtin_library.dart';

/// A NetEase playlist (歌单): header, description and its songs.
class SheetDetailPage extends StatefulWidget {
  final SheetInfo sheet;

  const SheetDetailPage({super.key, required this.sheet});

  @override
  State<SheetDetailPage> createState() => _SheetDetailPageState();
}

class _SheetDetailPageState extends State<SheetDetailPage> {
  final _scroll = ScrollController();
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;
  int _total = 0;
  int _page = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _moreError;

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
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
  }

  /// 歌单以前一次只取前 80 首，长歌单听一半就没了。现在按页取，滑到底自动接上。
  Future<void> _load({bool refresh = false}) async {
    setState(() {
      // 屏幕上已经有一屏歌就别把整页换成转圈：下拉刷新换来的是「先空一下」，
      // 比刷新本身慢不慢更难受，也害她以为点错了什么。
      _loading = _songs.isEmpty;
      _error = null;
      _moreError = null;
    });
    try {
      // 下拉刷新要绕过 5 分钟目录缓存，不然她以为刷新坏了。
      if (refresh) BuiltinLibrary.instance.invalidateCatalog();
      final res = await BuiltinLibrary.instance.sheetSongs(widget.sheet.source, widget.sheet.id);
      if (!mounted) return;
      setState(() {
        _page = 1;
        _songs = res.list;
        _total = res.total;
        _hasMore = res.list.isNotEmpty && _page < res.allPage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
      // 旧列表还在的时候那句错误没有地方显示（错误块只在空列表时出现），
      // 不吭一声的话「下拉刷新」看起来就是没反应。
      if (_songs.isNotEmpty) toast(context, '这个歌单没刷新下来：${humanizeError(e)}');
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
      final res = await BuiltinLibrary.instance
          .sheetSongs(widget.sheet.source, widget.sheet.id, page: next);
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
        _total = res.total;
        _hasMore = _page < res.allPage;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _moreError = humanizeError(e);
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final desc = widget.sheet.desc ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sheet.name),
        actions: [
          Builder(builder: (context) {
            final saved = context.select<LibraryStore, bool>((s) => s.isSheetSaved(widget.sheet));
            return IconButton(
              tooltip: saved ? '取消收藏' : '收藏歌单',
              icon: Icon(
                saved ? Icons.favorite : Icons.favorite_border,
                color: saved ? AppTheme.primary : null,
              ),
              onPressed: () => toggleSheetFavorite(context, widget.sheet),
            );
          }),
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
            : ListView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CoverTile(label: '', imageUrl: widget.sheet.img, size: 100),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.sheet.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                              if (_total > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('共 $_total 首',
                                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                ),
                              if (desc.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                ExpandableDesc(text: desc),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_songs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => context.read<PlayerService>().playList(_songs, 0),
                            icon: const Icon(Icons.play_arrow, size: 20),
                            label: Text(_total > _songs.length
                                ? '播放已加载 ${_songs.length} 首'
                                : '播放全部 ${_songs.length} 首'),
                          ),
                        ],
                      ),
                    ),
                  // 整单会员歌一次处理掉，比一首一首撞墙快得多。
                  VipScanBar(songs: _songs),
                  if (_error != null && _songs.isEmpty)
                    EmptyState(message: _error!, actionText: '重试', onAction: () => _load(refresh: true))
                  else if (_songs.isEmpty)
                    const EmptyState(message: '歌单是空的')
                  else ...[
                    for (var i = 0; i < _songs.length; i++)
                      SongListRow(
                        song: _songs[i],
                        number: i + 1,
                        siblings: _songs,
                      ),
                    _footer(),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }

  Widget _footer() {
    if (_moreError != null) {
      final left = _total - _songs.length;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(left > 0 ? '还有 $left 首没加载出来' : '后面那页没加载出来',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
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
      // 滑到离底 400 以内会自动接下一页，可歌单短到一屏就装完时那条触发永远等不到人，
      // 于是页脚就停在一根转个不停的圈上。给一颗点得到的键，转圈只在真在加载时出现。
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
    if (_songs.isNotEmpty) {
      // 到底要给句话，不然她一直往下滑，以为还有。
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('已经到底 · 共 ${_songs.length} 首',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    return const SizedBox.shrink();
  }
}
