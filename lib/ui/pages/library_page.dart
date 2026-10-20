import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../download/download_manager.dart';
import '../../library/library_store.dart';
import '../../library/user_playlist.dart';
import '../../models/results.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'eq_page.dart';
import 'settings_page.dart';
import 'sheet_detail_page.dart';
import 'sources_page.dart';
import 'user_playlist_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> implements ScrollToTop {
  final ScrollController _scroll = ScrollController();

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
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    return ListView(
      controller: _scroll,
      padding: EdgeInsets.zero,
      children: [
        SafeArea(
          bottom: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AppTheme.primaryLight, AppTheme.primary]),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 26,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.person, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('我的音乐', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
                  icon: const Icon(Icons.settings_outlined, color: Colors.white),
                  tooltip: '设置',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        _SettingsTile(
          icon: Icons.sensors,
          title: '音源管理',
          subtitle: '内置音源 / 自动更新 / 手动导入',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SourcesPage())),
        ),
        _SettingsTile(
          icon: Icons.tune,
          title: '均衡器',
          subtitle: '多种音效预设',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EqPage())),
        ),
        _SettingsTile(
          icon: Icons.settings_suggest_outlined,
          title: '播放设置',
          subtitle: '音质偏好 / 清除缓存',
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
        ),
        const _DownloadingSection(),
        Divider(height: 24, color: AppTheme.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              const Text('我的歌单', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _newPlaylist(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        _PlaylistSection(playlists: store.playlists),
        _SavedSheetsSection(sheets: store.savedSheets),
        Divider(height: 24, color: AppTheme.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('本地音乐', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        _Section(
            kind: LibraryKind.favorites,
            icon: Icons.favorite,
            title: '我的收藏',
            empty: '还没有收藏歌曲：列表右侧的 ♥，或长按任意一首在菜单里收藏'),
        _Section(kind: LibraryKind.recent, icon: Icons.history, title: '最近播放', empty: '暂无播放记录'),
        _Section(kind: LibraryKind.downloaded, icon: Icons.download, title: '下载管理', empty: '还没有下载歌曲'),
        if (store.list(LibraryKind.favorites).isEmpty && store.list(LibraryKind.recent).isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text('提示：在「首页」顶部搜索歌曲，或进「发现」页点榜单直接播放；长按任意歌单可以收藏到这里。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SettingsTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(backgroundColor: AppTheme.iconTint, child: Icon(icon, color: AppTheme.primary, size: 22)),
      title: Text(title),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
    );
  }
}

/// 自建歌单 list: tap to open, swipe-free remove lives inside the page.
class _PlaylistSection extends StatelessWidget {
  final List<UserPlaylist> playlists;
  const _PlaylistSection({required this.playlists});

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('还没有自建歌单\n在任意列表里长按一首歌，就能「加入歌单」',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.6)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        children: [
          for (final p in playlists)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              shape: RoundedRectangleBorder(borderRadius: AppTheme.cardBorder),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.iconTint,
                  child: Icon(Icons.playlist_play, color: AppTheme.primary, size: 22),
                ),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(p.songs.isEmpty ? '还没有歌曲' : '共 ${p.songs.length} 首',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => UserPlaylistPage(playlistId: p.id)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 收藏的网易云歌单：发现/搜索/首页长按，或进详情页点 ♥ 收进来。
class _SavedSheetsSection extends StatelessWidget {
  const _SavedSheetsSection({required this.sheets});

  final List<SheetInfo> sheets;

  @override
  Widget build(BuildContext context) {
    // 没收藏过就不占位置：收第一张的时候这一块会自己冒出来。
    if (sheets.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 24, color: AppTheme.divider),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Text('收藏的歌单 · ${sheets.length}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  final gone = LibraryStore.instance.clearSheets();
                  toast(context, '已清空收藏的歌单',
                      actionLabel: '撤销', onAction: () => LibraryStore.instance.restoreSheets(gone));
                },
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清空', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Column(
            children: [
              for (final s in sheets)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  shape: RoundedRectangleBorder(borderRadius: AppTheme.cardBorder),
                  child: ListTile(
                    leading: CoverTile(label: '', imageUrl: s.img, size: 46, icon: Icons.queue_music),
                    title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        (s.desc ?? '').isEmpty ? '来自 ${s.source}' : s.desc!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    trailing: IconButton(
                      icon: const Icon(Icons.favorite, color: AppTheme.primary, size: 20),
                      tooltip: '取消收藏',
                      onPressed: () => toggleSheetFavorite(context, s),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SheetDetailPage(sheet: s)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _newPlaylist(BuildContext context) async {
  final store = LibraryStore.instance;
  final name = await promptText(context, title: '新建歌单', hint: '歌单名称');
  if (name == null || name.trim().isEmpty) return;
  final created = store.createPlaylist(name);
  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => UserPlaylistPage(playlistId: created.id)));
}

class _Section extends StatefulWidget {
  final LibraryKind kind;
  final IconData icon;
  final String title;
  final String empty;
  const _Section({required this.kind, required this.icon, required this.title, required this.empty});

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final list = store.list(widget.kind);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: AppTheme.cardBorder),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => setState(() => _expanded = v),
          leading: CircleAvatar(
            backgroundColor: AppTheme.iconTint,
            child: Icon(widget.icon, color: AppTheme.primary, size: 22),
          ),
          title: Text(widget.title),
          subtitle: Text(list.isEmpty ? widget.empty : '共 ${list.length} 首',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          children: list.isEmpty
              ? const [SizedBox(height: 4)]
              : [
                  // 一首一首 × 点掉太累，最近播放本来就没有留档价值。
                  if (widget.kind == LibraryKind.recent)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            final gone = store.clear(LibraryKind.recent);
                            toast(context, '已清空最近播放',
                                actionLabel: '撤销',
                                onAction: () => store.restore(LibraryKind.recent, gone));
                          },
                          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                          label: const Text('清空最近播放', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ),
                  for (var i = 0; i < list.length && i < 50; i++)
                    SongListRow(
                      song: list[i],
                      siblings: list,
                      active: context.select<PlayerService, bool>((p) => p.isCurrent(list[i])),
                      extraTrailing: _RemoveButton(kind: widget.kind, song: list[i]),
                    ),
                  if (list.length > 50)
                    ListTile(
                      dense: true,
                      title: Text('查看全部 ${list.length} 首',
                          style: TextStyle(fontSize: 13, color: AppTheme.primary)),
                      trailing: Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => _FullListPage(kind: widget.kind, title: widget.title)),
                      ),
                    ),
                  const SizedBox(height: 4),
                ],
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  final LibraryKind kind;
  final Song song;
  const _RemoveButton({required this.kind, required this.song});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
      tooltip: kind == LibraryKind.downloaded ? '删除本地文件' : '移出列表',
      onPressed: () async {
        if (kind == LibraryKind.downloaded) {
          // 文件删了没法撤销，得先问一句。
          final ok = await confirmAction(context,
              title: '删除本地文件',
              message: '删除后这首歌会回到在线播放，想再离线听需要重新下载。');
          if (!ok || !context.mounted) return;
          await context.read<DownloadManager>().deleteDownload(song);
          if (!context.mounted) return;
          toast(context, '已删除「${song.name}」的本地文件');
          return;
        }
        final store = context.read<LibraryStore>();
        final at = store.remove(kind, song);
        if (at < 0 || !context.mounted) return;
        toast(context, kind == LibraryKind.favorites ? '已取消收藏' : '已移出列表',
            actionLabel: '撤销', onAction: () => store.putBack(kind, song, at));
      },
    );
  }
}

/// Downloads in flight or failed — previously they were only visible as an icon
/// on the player page, so a stalled 无损 file looked like a dead button.
class _DownloadingSection extends StatelessWidget {
  const _DownloadingSection();

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    final shown = dm.tasks.where((t) => t.running || t.error != null).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: AppTheme.cardBorder),
      child: Column(
        children: [
          for (final t in shown)
            ListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -1),
              leading: Icon(
                t.error != null ? Icons.error_outline : Icons.downloading_outlined,
                color: t.error != null ? AppTheme.primary : AppTheme.textSecondary,
              ),
              title: Text(t.song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: t.error != null
                  ? Text('下载失败：${t.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppTheme.primary))
                  : _ProgressBar(task: t),
              trailing: t.error != null
                  ? IconButton(
                      icon: Icon(Icons.refresh, size: 20, color: AppTheme.textSecondary),
                      tooltip: '重试',
                      onPressed: () => dm.retry(t),
                    )
                  : IconButton(
                      icon: Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                      tooltip: '取消下载',
                      onPressed: () => dm.cancel(t),
                    ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final DownloadTask task;
  const _ProgressBar({required this.task});

  @override
  Widget build(BuildContext context) {
    final p = task.progress;
    return Padding(
      padding: const EdgeInsets.only(right: 10, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p == null
                ? '${task.quality} · 正在连接'
                : '${task.quality} · ${(p * 100).clamp(0, 100).toInt()}%  ·  '
                    '${(task.received / 1048576).toStringAsFixed(1)}/${(task.total / 1048576).toStringAsFixed(1)} MB',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 3),
          LinearProgressIndicator(
            value: p,
            minHeight: 3,
            backgroundColor: AppTheme.divider,
            valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
          ),
        ],
      ),
    );
  }
}

/// 收藏 / 最近播放超过 50 首时的完整列表：ExpansionTile 里铺几百行会明显卡顿。
class _FullListPage extends StatelessWidget {
  final LibraryKind kind;
  final String title;
  const _FullListPage({required this.kind, required this.title});

  @override
  Widget build(BuildContext context) {
    final list = context.watch<LibraryStore>().list(kind);
    return Scaffold(
      appBar: AppBar(
        title: Text('$title · ${list.length}'),
        actions: [
          if (list.isNotEmpty)
            IconButton(
              tooltip: '播放全部',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => context.read<PlayerService>().playList(list, 0),
            ),
        ],
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: list.isEmpty
          ? const EmptyState(message: '这个列表已经空了')
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.divider),
              itemBuilder: (context, i) => SongListRow(
                song: list[i],
                number: i + 1,
                siblings: list,
                active: context.select<PlayerService, bool>((p) => p.isCurrent(list[i])),
                extraTrailing: _RemoveButton(kind: kind, song: list[i]),
              ),
            ),
    );
  }
}
