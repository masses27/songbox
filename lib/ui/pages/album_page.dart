import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist_page.dart';
import 'builtin_library.dart';

/// 专辑页: cover, credits and every track on the record.
class AlbumPage extends StatefulWidget {
  final String albumId;
  final String? seedName;

  const AlbumPage({super.key, required this.albumId, this.seedName});

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  AlbumInfo? _album;
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;

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
    try {
      // 下拉刷新先清掉 5 分钟目录缓存，不然刷出来的还是同一份数据。
      if (refresh) BuiltinLibrary.instance.invalidateCatalog();
      final res = await BuiltinLibrary.instance.album(widget.albumId);
      if (!mounted) return;
      setState(() {
        _album = res.album;
        _songs = res.songs;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    return Scaffold(
      appBar: AppBar(title: Text(album?.name ?? widget.seedName ?? '专辑')),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: _loading && album == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && album == null
                ? ListView(
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
                      _Head(album: album!, songs: _songs.length, onArtistTap: _openArtist),
                      if (album.desc.isNotEmpty)
                        ExpandableDesc(text: album.desc, padding: const EdgeInsets.fromLTRB(16, 2, 16, 10)),
                      if (_songs.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: ElevatedButton.icon(
                            onPressed: () => context.read<PlayerService>().playList(_songs, 0),
                            icon: const Icon(Icons.play_arrow, size: 20),
                            label: Text('播放全部 ${_songs.length} 首'),
                          ),
                        ),
                      for (var i = 0; i < _songs.length; i++)
                        SongListRow(
                          song: _songs[i],
                          number: i + 1,
                          siblings: _songs,
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
      ),
    );
  }

  void _openArtist(String artistId, String name) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ArtistPage(artistId: artistId, seedName: name)),
    );
  }
}

class _Head extends StatelessWidget {
  final AlbumInfo album;
  final int songs;
  final void Function(String id, String name) onArtistTap;

  const _Head({required this.album, required this.songs, required this.onArtistTap});

  @override
  Widget build(BuildContext context) {
    final year = album.publishYear;
    final meta = [
      if (album.artist.isNotEmpty) album.artist,
      if (year.isNotEmpty) year,
      if (album.size > 0 || songs > 0) '${songs > 0 ? songs : album.size} 首',
    ].join(' · ');
    final metaStyle = TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4);
    final goArtist = album.artistId.isNotEmpty && album.artist.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverTile(label: '', imageUrl: album.pic, size: 104, icon: Icons.album_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(album.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // 能跳歌手时给个箭头：这行字看着就是描述，不点进去她不知道能按。
                  if (!goArtist)
                    Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis, style: metaStyle)
                  else
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onArtistTap(album.artistId, album.artist),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(meta,
                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: metaStyle),
                            ),
                            Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
                          ],
                        ),
                      ),
                    ),
                ],
                if (album.type.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(album.type, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
