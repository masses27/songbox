import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../player/player_service.dart';
import '../theme.dart';
import '../widgets.dart';

/// Bottom sheet over the current play queue: jump, drop, change the loop mode.
Future<void> showPlayQueue(BuildContext context) => showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.pageBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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
      if (!ctrl.hasClients) return;
      final target = (index - 1) * _rowH;
      ctrl.jumpTo(target > ctrl.position.maxScrollExtent ? ctrl.position.maxScrollExtent : target);
    });
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
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, ctrl) {
        _locateCurrent(ctrl, player.index);
        return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Text('播放队列 · ${player.queue.length} 首',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
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
          Divider(height: 1, color: AppTheme.divider),
          Expanded(
            child: player.queue.isEmpty
                ? Center(child: Text('队列是空的', style: TextStyle(color: AppTheme.textSecondary)))
                : ReorderableListView.builder(
                    scrollController: ctrl,
                    buildDefaultDragHandles: false,
                    itemCount: player.queue.length,
                    onReorderItem: player.moveInQueue,
                    proxyDecorator: (child, _, _) => Material(
                      color: AppTheme.pageBg.withValues(alpha: .95),
                      borderRadius: BorderRadius.circular(8),
                      elevation: 4,
                      child: child,
                    ),
                    itemBuilder: (context, i) {
                      final s = player.queue[i];
                      final active = i == player.index;
                      return ListTile(
                        key: ValueKey('$active:$i:${s.source}:${s.songmid}'),
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -1),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: SizedBox(
                            width: 30,
                            child: active
                                ? const Icon(Icons.equalizer_rounded, color: AppTheme.primary, size: 20)
                                : Icon(Icons.drag_handle, color: AppTheme.textSecondary, size: 20),
                          ),
                        ),
                        title: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                                color: active ? AppTheme.primary : AppTheme.textPrimary)),
                        subtitle: Text(s.singer,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        trailing: IconButton(
                          icon: Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
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
          ),
        ],
      );
      },
    );
  }
}
