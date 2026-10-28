import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../player/player_service.dart';
import '../theme.dart';
import '../widgets.dart';

/// Bottom sheet over the current play queue: jump, drop, change the loop mode.
Future<void> showPlayQueue(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: AppTheme.sheetConstraints(context),
      builder: (_) => const _PlayQueueSheet(),
    );

class _PlayQueueSheet extends StatefulWidget {
  const _PlayQueueSheet();

  @override
  State<_PlayQueueSheet> createState() => _PlayQueueSheetState();
}

class _PlayQueueSheetState extends State<_PlayQueueSheet> {
  static const double _rowH = 56;
  bool _located = false;

  /// 队列上百首、正播到第六十首时，打开面板却看见队首等于没看见。
  /// 只在建好第一帧时挪一次，之后面板随 PlayerService 反复重建都不再动。
  void _locateCurrent(ScrollController ctrl, int index) {
    if (_located || index < 2) return;
    _located = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jump(ctrl, index);
    });
  }

  void _jump(ScrollController ctrl, int index) {
    if (!ctrl.hasClients) return;
    final target = (index - 1) * _rowH;
    ctrl.jumpTo(target.clamp(0.0, ctrl.position.maxScrollExtent).toDouble());
  }

  void _remove(PlayerService player, int i) {
    final song = player.queue[i];
    final last = player.queue.length == 1;
    player.removeFromQueue(i);
    // 移除最后一首会把播放整个停掉，撤销也就得重新起播一次。
    toast(context, '已移除「${song.name}」',
        actionLabel: '撤销',
        onAction: () => last ? player.playList([song], 0) : player.reinsertInQueue(i, song));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    // Scaffold 必须在可拖动区域里面，否则会把整张弹层撑满窗口。
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.45,
      maxChildSize: 1,
      builder: (context, ctrl) {
        _locateCurrent(ctrl, player.index);
        return ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              top: false,
              child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('播放队列 · ${player.queue.length} 首',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    TextButton.icon(
                      onPressed: player.cyclePlayMode,
                      icon: Icon(player.playModeIcon, size: 18),
                      label: Text(player.playModeLabel, style: const TextStyle(fontSize: 12)),
                    ),
                    if (player.queue.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          // 清空会顺手把正在播的也停掉，一次误触就把一下午排的队没了，
                          // 所以先记下快照，提示条里给 3 秒撤销。
                          final snapshot = List<Song>.of(player.queue);
                          final at = player.index.clamp(0, snapshot.length - 1);
                          toast(context, '已清空 ${snapshot.length} 首的队列',
                              actionLabel: '撤销',
                              onAction: () => player.playList(snapshot, at));
                          await player.stopAndClear();
                          if (context.mounted) Navigator.pop(context);
                        },
                        child: const Text('清空', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: player.queue.isEmpty
                    ? Center(child: Text('队列是空的', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)))
                    : Stack(
                        children: [
                          ReorderableListView.builder(
                            scrollController: ctrl,
                            buildDefaultDragHandles: false,
                            itemCount: player.queue.length,
                            onReorderItem: player.moveInQueue,
                            proxyDecorator: (child, _, _) => Material(
                              color: Theme.of(context).colorScheme.surface.withValues(alpha: .95),
                              borderRadius: BorderRadius.circular(8),
                              elevation: 4,
                              child: child,
                            ),
                            itemBuilder: (context, i) {
                              final s = player.queue[i];
                              final active = i == player.index;
                              return ListTile(
                                // 键里别掺「在不在播」「排第几」这类会变的东西：一次切歌
                                // 就把整列的键换一遍，拖拽中途还会把手感丢掉。
                                // 序号还是要留着：同一首歌被排进队列两次，光靠 id 会撞键。
                                key: ValueKey('${s.source}:${s.songmid}:$i'),
                                dense: true,
                                visualDensity: const VisualDensity(vertical: -1),
                                leading: ReorderableDragStartListener(
                                  index: i,
                                  child: SizedBox(
                                    width: 30,
                                    child: active
                                        ? const Icon(Icons.equalizer_rounded, color: AppTheme.primary, size: 20)
                                        : Icon(Icons.drag_handle, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                                  ),
                                ),
                                title: Text(s.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                                        color: active ? AppTheme.primary : Theme.of(context).colorScheme.onSurface)),
                                subtitle: Text(s.singer,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                trailing: IconButton(
                                  icon: Icon(Icons.close, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                  tooltip: '从队列移除',
                                  onPressed: () => _remove(player, i),
                                ),
                                onTap: () {
                                  player.playAt(i);
                                  Navigator.pop(context);
                                },
                              );
                            },
                          ),
                          // 翻到队列中间之后，「那一首在哪儿」得重新往上滑很久。
                          if (player.queue.length > 8 && player.index >= 2)
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).cardColor,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Theme.of(context).dividerColor),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: () => _jump(ctrl, player.index),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                                    child: Row(
                                      children: [
                                        Icon(Icons.my_location, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                        const SizedBox(width: 4),
                                        const Text('在播这首', style: TextStyle(fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
              ),
            ),
          ),
        );
      },
    );
  }
}
