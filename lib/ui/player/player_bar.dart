import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/art_url.dart';
import '../theme.dart';
import 'player_page.dart';
import 'queue_sheet.dart';

/// Mini player that lives in every screen's [Scaffold.bottomNavigationBar]:
/// drag to seek, tap to open the full page.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, this.reserveNavInset = true});

  /// 根页面下方还有标签栏，标签栏自己会避开系统导航条；其他页面播放条就是最底下一层，
  /// 得自己垫出这段高度，否则手势条会压在按钮上。
  final bool reserveNavInset;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  /// Milliseconds the finger is holding on the track, or null when not dragging.
  int? _scrub;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();
    final inset = widget.reserveNavInset ? MediaQuery.viewPaddingOf(context).bottom : 0.0;
    return Material(
      color: AppTheme.pageBg,
      shadowColor: Colors.black26,
      elevation: 6,
      child: StreamBuilder<PlayerState>(
        stream: player.playerStateStream,
        builder: (context, snap) {
          final playing = snap.data?.playing == true;
          final loading = player.busy || snap.data?.processingState == ProcessingState.loading;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ScrubBar(player: player, scrub: _scrub, onScrub: _onScrub),
              GestureDetector(
                onHorizontalDragEnd: (d) => _swipe(d.primaryVelocity ?? 0, player),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 440 || MediaQuery.textScalerOf(context).scale(14) > 18;
                    final details = InkWell(
                      onTap: () => _openPlayerPage(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(
                          children: [
                            _Cover(song: song),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    player.busy ? '正在获取播放地址…' : song.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  Text(
                                    // 等重连这一句要常驻：提示条两秒就收，而那后面可能是 15 秒、30 秒。
                                    player.waitNote ?? song.singer,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: player.waitNote == null ? AppTheme.textSecondary : AppTheme.primary),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    final controls = Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        SizedBox.square(
                          dimension: 48,
                          child: PopupMenuButton<PlayMode>(
                            tooltip: player.playModeLabel,
                            initialValue: player.playMode,
                            icon: Icon(player.playModeIcon, size: 22, color: AppTheme.textSecondary),
                            onSelected: player.setPlayMode,
                            itemBuilder: (_) => [
                              for (final mode in PlayMode.values)
                                CheckedPopupMenuItem<PlayMode>(
                                  value: mode,
                                  checked: mode == player.playMode,
                                  child: Row(
                                    children: [
                                      Icon(mode.icon, size: 20),
                                      const SizedBox(width: 12),
                                      Flexible(child: Text(mode.label)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        _TinyButton(
                          icon: Icons.skip_previous,
                          tooltip: '上一首',
                          onPressed: () => player.previous(),
                        ),
                        IconButton(
                          iconSize: 30,
                          tooltip: playing ? '暂停' : '播放',
                          visualDensity: VisualDensity.standard,
                          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                          padding: EdgeInsets.zero,
                          onPressed: () => player.togglePlay(),
                          icon: loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.4, color: AppTheme.primary),
                                )
                              : Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_outline,
                                  color: AppTheme.primary),
                        ),
                        _TinyButton(icon: Icons.skip_next, tooltip: '下一首', onPressed: () => player.next()),
                        _TinyButton(
                          icon: Icons.queue_music_outlined,
                          tooltip: '播放队列',
                          // 队列里有几首，图标上就标几个——网易云也是这个数字，
                          // 不用打开面板就知道后面还排着多少。
                          badge: player.queue.length,
                          onPressed: () => showPlayQueue(context),
                        ),
                      ],
                    );
                    return compact
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [details, controls],
                          )
                        : Row(
                            children: [Expanded(child: details), controls, const SizedBox(width: 8)],
                          );
                  },
                ),
              ),
              if (inset > 0) SizedBox(height: inset),
            ],
          );
        },
      ),
    );
  }

  /// 播放页只留一份：反复点迷你条会叠出一摞同样的页面，往回退要连按好几次返回。
  void _openPlayerPage(BuildContext context) {
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.settings.name != _playerRoute);
    nav.push(MaterialPageRoute(
      builder: (_) => const PlayerPage(),
      settings: const RouteSettings(name: _playerRoute),
    ));
  }

  void _onScrub(int? ms) => setState(() => _scrub = ms);

  /// 手指横着一划就切歌：条已经到处都在了，划一下比去点那几个小图标顺手，
  /// 也省得为了上一首/下一首再往标题里挤按钮。
  void _swipe(double velocity, PlayerService player) {
    if (velocity.abs() < 260) return;
    if (velocity < 0) {
      player.next();
    } else {
      player.previous();
    }
  }
}

const _playerRoute = 'player-page';

class _TinyButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// 显示在图标右上角的计数，null 或 0 不显示。
  final int? badge;
  const _TinyButton(
      {required this.icon,
      required this.tooltip,
      required this.onPressed,
      this.badge});

  @override
  Widget build(BuildContext context) {
    final n = badge ?? 0;
    return IconButton(
      icon: n == 0
          ? Icon(icon, size: 22, color: AppTheme.textSecondary)
          : Badge.count(
              count: n,
              backgroundColor: AppTheme.primary,
              // 徽标压在图标右上角，超出按钮 4px 就会被裁掉。
              padding: const EdgeInsets.symmetric(horizontal: 3.5),
              child: Icon(icon, size: 22, color: AppTheme.textSecondary),
            ),
      tooltip: tooltip,
      visualDensity: VisualDensity.standard,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _Cover extends StatelessWidget {
  final Song song;
  const _Cover({required this.song});

  @override
  Widget build(BuildContext context) {
    final pic = song.pic;
    if (pic == null || pic.isEmpty) return const Icon(Icons.music_note);
    final px = (40 * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: artUrl(pic, px: px)!,
        httpHeaders: artHeaders,
        width: 40,
        height: 40,
        memCacheWidth: px,
        memCacheHeight: px,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => const Icon(Icons.music_note),
      ),
    );
  }
}

/// Thin but draggable progress line — one thumb near the keyboard is enough to
/// jump ahead in a song without opening the full player.
class _ScrubBar extends StatelessWidget {
  final PlayerService player;
  final int? scrub;
  final ValueChanged<int?> onScrub;
  const _ScrubBar({required this.player, required this.scrub, required this.onScrub});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, s) {
        // 长度先认播放器、再认曲库里那份 interval（见 PlayerService.total）。在线流开头
        // 几秒不报 duration，那时候整条进度线只能退化成一根转圈的模糊线：拖不动，
        // 也看不出这首歌还剩多久。
        final totalMs = player.total?.inMilliseconds ?? 0;
        if (totalMs <= 0) {
          return SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              value: null,
              backgroundColor: AppTheme.divider,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
            ),
          );
        }
        // 手指压着的时候认手指，刚松手那一截认 seekHold，其余才是播放器报的位置。
        // 少了中间那一项，seek 落地之前进度头会先弹回原来的地方再跳过去 —— 像没拖准。
        final value = (scrub ?? player.seekHold?.inMilliseconds ?? s.data?.inMilliseconds ?? 0)
            .clamp(0, totalMs)
            .toDouble();
        return SizedBox(
          // 轨道只有 2px，能按到的却是这一整条的高度：16 的时候得瞄着点，
          // 24 才勉强是「手指随便一压就中」。
          height: 24,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: AppTheme.divider,
              thumbColor: AppTheme.primary,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: Slider(
              value: value,
              max: totalMs.toDouble(),
              onChangeStart: (v) => onScrub(v.round()),
              onChanged: (v) => onScrub(v.round()),
              onChangeEnd: (v) {
                player.seek(Duration(milliseconds: v.round()));
                onScrub(null);
              },
            ),
          ),
        );
      },
    );
  }
}
