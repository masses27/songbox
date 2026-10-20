import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../library/library_store.dart';
import '../../library/user_playlist.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'search_page.dart';

/// One 自建歌单: its songs, in the order they were added.
class UserPlaylistPage extends StatefulWidget {
  final String playlistId;

  const UserPlaylistPage({super.key, required this.playlistId});

  @override
  State<UserPlaylistPage> createState() => _UserPlaylistPageState();
}

class _UserPlaylistPageState extends State<UserPlaylistPage> {
  /// 排序模式：拖动列表重排，松手即落盘。
  bool _sorting = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final playlist = store.playlist(widget.playlistId);
    if (playlist == null) {
      // Deleted while we were on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.pop(context);
      });
      return Scaffold(backgroundColor: AppTheme.pageBg);
    }
    final songs = playlist.songs;
    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          if (songs.length > 1)
            IconButton(
              tooltip: _sorting ? '完成排序' : '调整顺序',
              icon: Icon(_sorting ? Icons.check : Icons.drag_handle, size: 22),
              onPressed: () => setState(() => _sorting = !_sorting),
            ),
          IconButton(
            tooltip: '重命名',
            icon: const Icon(Icons.edit_outlined, size: 22),
            onPressed: () => _rename(context, playlist),
          ),
          IconButton(
            tooltip: '删除歌单',
            icon: const Icon(Icons.delete_outline, size: 22),
            onPressed: () => _delete(context, playlist),
          ),
        ],
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: songs.isEmpty
          ? ListView(
              children: [
                EmptyState(
                  icon: Icons.playlist_add,
                  message: '这个歌单还是空的\n在任意列表里长按一首歌，就能「加入歌单」',
                  actionText: '去搜歌',
                  onAction: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchPage())),
                ),
              ],
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${songs.length} 首',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => context.read<PlayerService>().playList(songs, 0),
                        icon: const Icon(Icons.play_arrow, size: 20),
                        label: const Text('播放全部'),
                      ),
                    ],
                  ),
                ),
                VipScanBar(songs: songs),
                Expanded(
                  child: _sorting
                      ? ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: songs.length,
                          header: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                            child: Text('按住右侧把手拖动，松手就保存',
                                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          ),
                          onReorderItem: (from, to) => store.reorderPlaylist(playlist.id, from, to),
                          itemBuilder: (context, i) {
                            final s = songs[i];
                            return ListTile(
                              key: ValueKey(LibraryStore.keyOf(s)),
                              dense: true,
                              visualDensity: const VisualDensity(vertical: -1),
                              title: Text(s.name.isEmpty ? '未知歌曲' : s.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14.5)),
                              subtitle: Text(s.singer,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12)),
                              trailing: ReorderableDragStartListener(
                                  index: i, child: const Icon(Icons.drag_handle)),
                            );
                          },
                        )
                      : ListView.separated(
                          itemCount: songs.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.divider),
                          itemBuilder: (context, i) {
                            final s = songs[i];
                            return SongListRow(
                              song: s,
                              siblings: songs,
                              active: context.select<PlayerService, bool>((p) => p.isCurrent(s)),
                              extraTrailing: IconButton(
                                icon: Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                                tooltip: '从本歌单移除',
                                onPressed: () => _remove(store, playlist, s),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  /// 移出单曲给一次撤销：手滑点错 × 就要重新搜一遍再加回来，代价太大了。
  void _remove(LibraryStore store, UserPlaylist playlist, Song s) {
    final at = store.removeFromPlaylist(playlist.id, s);
    toast(context, '已移出「${s.name}」',
        actionLabel: at < 0 ? null : '撤销',
        onAction: at < 0 ? null : () => store.putBackInPlaylist(playlist.id, s, at));
  }

  Future<void> _rename(BuildContext context, UserPlaylist playlist) async {
    final store = LibraryStore.instance;
    final name = await promptText(context,
        title: '重命名歌单', hint: '歌单名称', initial: playlist.name);
    if (name == null || !context.mounted) return;
    if (name.trim().isEmpty) {
      // 清空名字点确定原本什么都不发生，看着像按钮坏了。
      toast(context, '歌单名字不能是空的');
      return;
    }
    store.renamePlaylist(playlist.id, name);
  }

  Future<void> _delete(BuildContext context, UserPlaylist playlist) async {
    final store = LibraryStore.instance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${playlist.name}」'),
        content: const Text('只删这个歌单和它记的歌，下载好的文件与收藏都不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    store.deletePlaylist(playlist.id);
    if (context.mounted) Navigator.pop(context);
  }
}
