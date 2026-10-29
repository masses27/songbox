import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'album_page.dart';
import 'builtin_library.dart';

/// 歌手页: avatar, hot songs and the discography, the way 网易云 groups them.
class ArtistPage extends StatefulWidget {
  final String artistId;
  final String? seedName;

  const ArtistPage({super.key, required this.artistId, this.seedName});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  ArtistInfo? _artist;
  List<Song> _songs = const [];
  List<AlbumInfo> _albums = const [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;
  int _page = 1;
  int _allPage = 1;
  final Set<String> _seen = {};

  bool get _hasMore =>
      _page < _allPage || (_page == 1 && (_artist?.musicSize ?? 0) > _songs.length);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final lib = BuiltinLibrary.instance;
    try {
      // 下拉刷新要清掉 5 分钟目录缓存，否则刷出来还是那一份。
      if (refresh) lib.invalidateCatalog();
      final detail = await lib.artist(widget.artistId);
      if (!mounted) return;
      setState(() {
        _artist = detail.artist;
        _songs = detail.songs;
        _seen
          ..clear()
          ..addAll(detail.songs.map((s) => s.songmid));
        _page = 1;
        _allPage = 1;
        _moreError = null;
      });
      // The discography is a second call; a failure here should not lose the songs.
      try {
        final albums = await lib.artistAlbums(widget.artistId);
        if (mounted) setState(() => _albums = albums);
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 首屏只有网易云给的 50 首热门，剩下的一页页点出来。
  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final res = await BuiltinLibrary.instance.artistSongs(widget.artistId, page: _page + 1);
      if (!mounted) return;
      final fresh = res.list.where((s) => _seen.add(s.songmid)).toList();
      final loaded = _songs.length + fresh.length;
      setState(() {
        _page += 1;
        // 接口不再给新歌就停住，别留一个点了没反应的按钮。
        _allPage = fresh.isNotEmpty && (res.total <= 0 || loaded < res.total) ? res.allPage : _page;
        if (fresh.isNotEmpty) _songs = [..._songs, ...fresh];
      });
    } catch (e) {
      if (mounted) setState(() => _moreError = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Widget _songsFooter() {
    if (_moreError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          children: [
            Text('后面的歌没加载出来', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            TextButton(onPressed: _loadMore, child: const Text('重试', style: TextStyle(fontSize: 13))),
          ],
        ),
      );
    }
    if (_hasMore) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: TextButton.icon(
            onPressed: _loadingMore ? null : _loadMore,
            icon: _loadingMore
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.expand_more, size: 18),
            label: Text(_loadingMore ? '正在加载…' : '查看更多歌曲', style: const TextStyle(fontSize: 13)),
          ),
        ),
      );
    }
    if (_page > 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text('已经全部加载 · 共 ${_songs.length} 首',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final artist = _artist;
    final name = artist?.name ?? widget.seedName ?? '歌手';
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        // 桌面上这一颗是这一页唯一的刷新入口：鼠标拖不动下拉刷新。
        actions: [DesktopRefreshButton(onRefresh: () => _load(refresh: true), busy: _loading)],
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: _loading && artist == null
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 160), Center(child: CircularProgressIndicator())],
              )
            : _error != null && artist == null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      EmptyState(
                          message: _error!,
                          icon: Icons.cloud_off,
                          actionText: '重试',
                          onAction: () => _load(refresh: true))
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      _Header(artist: artist!, songs: _songs),
                      if (_songs.isNotEmpty) ...[
                        SectionHeader('歌曲 · ${_songs.length}',
                            actionText: '播放全部',
                            onAction: () => context.read<PlayerService>().playList(_songs, 0)),
                        for (var i = 0; i < _songs.length; i++)
                          SongListRow(
                            song: _songs[i],
                            number: i + 1,
                            siblings: _songs,
                          ),
                        _songsFooter(),
                      ],
                      if (_albums.isNotEmpty) ...[
                        // 横条只摆 30 张，标题要说清是「前 30」还是全部，别让人以为歌手就这些专辑。
                        SectionHeader(_albums.length > 30
                            ? '专辑 · 前 30 / 共 ${_albums.length} 张'
                            : '专辑 · ${_albums.length}'),
                        _AlbumStrip(albums: _albums),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final ArtistInfo artist;
  final List<Song> songs;
  const _Header({required this.artist, required this.songs});

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (artist.alias.isNotEmpty) artist.alias,
      if (artist.musicSize > 0) '${artist.musicSize} 首歌曲',
      if (artist.albumSize > 0) '${artist.albumSize} 张专辑',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: CoverTile(label: '', imageUrl: artist.pic, size: 84),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(artist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                if (parts.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(parts.join(' · '),
                      maxLines: 2,
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
                ],
                if (artist.desc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // 简介压两行根本读不完，点一下展开全文。
                  ExpandableDesc(text: artist.desc),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumStrip extends StatelessWidget {
  final List<AlbumInfo> albums;
  const _AlbumStrip({required this.albums});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 152,
      child: MouseDragScroll(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: albums.length > 30 ? 30 : albums.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final a = albums[i];
            return GestureDetector(
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => AlbumPage(albumId: a.id, seedName: a.name))),
              child: SizedBox(
                width: 106,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CoverTile(label: '', imageUrl: a.pic, size: 106, icon: Icons.album_outlined),
                    const SizedBox(height: 4),
                    Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    Text(a.publishYear,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
