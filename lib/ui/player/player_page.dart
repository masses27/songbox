import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../download/download_manager.dart';
import '../../library/library_store.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../settings/app_settings.dart';
import '../../util/art_url.dart';
import '../../util/cover_tint.dart';
import '../../util/humanize.dart';
import '../pages/eq_page.dart';
import '../pages/settings_page.dart';
import '../theme.dart';
import '../widgets.dart';
import 'queue_sheet.dart';

/// '5:03' left on the sleep timer; hours only show up when they exist.
String _fmtLeft(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// 音质后面那半句：这一耳朵的声音到底是从哪条来的。
///
/// 换源和免费版一直是「暗地里」生效的——她看到歌名还是那首歌，却听不出到底
/// 走没走成，只能靠猜。写出来才算说清楚「一首歌一个源」是真的在按首生效。
String _nowTag(PlayerService player, Song song) {
  if (player.busy) return '加载中…';
  final swap = LibraryStore.instance.swapSongFor(song);
  // 档位按真正出声的那条来源算：换到 B 站的歌还写设置里的无损，就是骗人。
  final tier = heardQuality(AppSettings.instance.quality, swap?.source ?? song.source);
  if (LibraryStore.instance.localFile(song) != null) return '$tier · 本地文件';
  if (swap != null) return '$tier · ${song.twinBlocked ? '免费版' : sourceLabel(swap.source)}';
  return '$tier · ${sourceLabel(song.source)}';
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 22))
        ..value = 0;
  StreamSubscription<bool>? _playingSub;

  /// 当前背景色对应的封面 URL 与取到的主色。
  String? _tintKey;
  Color? _tint;

  @override
  void initState() {
    super.initState();
    final player = PlayerService.instance;
    _syncSpin(player.isPlaying);
    _playingSub = player.playingStream.listen(_syncSpin);
  }

  /// 换歌就把背景色重取一次；缓存里已有就立刻用上，避免先灰后色的闪一下。
  void _syncTint(Song song) {
    // 取色只需要 32×32，但底图本身也要给背景用，200 方足够；
    // 原图是 1 MB 上下的话，切歌时那层颜色会慢半拍才跟上。
    final pic = artUrl(song.pic, px: 200);
    if (pic == _tintKey) return;
    _tintKey = pic;
    _tint = pic == null ? null : CoverTint.peek(pic);
    if (pic != null && _tint == null) unawaited(_loadTint(pic));
  }

  Future<void> _loadTint(String pic) async {
    final color = await CoverTint.get(pic);
    if (color == null || !mounted || pic != _tintKey) return;
    setState(() => _tint = color);
  }

  void _syncSpin(bool playing) {
    if (!mounted) return;
    if (playing) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final song = player.current;
    if (song == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF1E1E1E),
        body: Center(child: Text('未在播放', style: TextStyle(color: Colors.white54))),
      );
    }
    _syncTint(song);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _Backdrop(pic: _tintKey, tint: _tint),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 32)),
                    const Spacer(),
                    Text(song.albumName?.isNotEmpty == true ? song.albumName! : song.name,
                        style: const TextStyle(color: Colors.white70, fontSize: 14)),
                    const Spacer(),
                    Consumer<LibraryStore>(
                      builder: (_, store, _) {
                        final fav = store.isFavorite(song);
                        return IconButton(
                          tooltip: fav ? '取消收藏' : '收藏',
                          onPressed: () {
                            store.toggleFavorite(song);
                            if (fav) {
                              toast(context, '已取消收藏',
                                  actionLabel: '撤销',
                                  onAction: () => store.toggleFavorite(song));
                            }
                          },
                          icon: Icon(
                            fav ? Icons.favorite : Icons.favorite_border,
                            color: fav ? AppTheme.primaryLight : Colors.white70,
                            size: 26,
                          ),
                        );
                      },
                    ),
                    Consumer<DownloadManager>(
                      builder: (_, dm, _) {
                        final id = '${song.source}:${song.songmid}';
                        final task = dm.tasks.firstWhere((t) => t.id == id,
                            orElse: () => DownloadTask(id: id, song: song, quality: AppSettings.instance.quality));
                        final running = task.running && !task.done;
                        final local = LibraryStore.instance.hasLocalFile(song);
                        return IconButton(
                          tooltip: local
                              ? '已下载到本地'
                              : (running ? '下载中 ${((task.progress ?? 0) * 100).toInt()}%' : '下载'),
                          onPressed: local || running ? null : () => requestDownload(context, song),
                          icon: Icon(
                            local ? Icons.download_done : (running ? Icons.downloading : Icons.download),
                            color: Colors.white70,
                            size: 26,
                          ),
                        );
                      },
                    ),
                    _MoreMenu(player: player),
                  ],
                ),
                Expanded(child: _Disc(spin: _spin, song: song)),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
                      ),
                      if (LibraryStore.instance.hasLocalFile(song))
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(Icons.wifi_off, color: Colors.white38, size: 16),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(song.singer,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      ),
                      if (player.sleepActive) ...[
                        Text('定时 ${_fmtLeft(player.sleepRemaining)}',
                            style: const TextStyle(color: AppTheme.primaryLight, fontSize: 11)),
                        const Text(' · ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      ],
                      Text(_nowTag(player, song),
                          style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                ),
                if (player.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(player.error!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xFFFF8A8A), fontSize: 12)),
                        ),
                        // 会员墙这类错重试没用的，先给「换版本」。
                        if (player.failedSong != null && looksLikeVipWall(player.error))
                          TextButton(
                              onPressed: () => showOtherVersionsSheet(context, player.failedSong!),
                              child: const Text('换版本', style: TextStyle(color: Colors.white70))),
                        TextButton(onPressed: player.retry, child: const Text('重试', style: TextStyle(color: Colors.white70))),
                      ],
                    ),
                  ),
                Expanded(flex: 2, child: _LyricView(player: player)),
                _Controls(player: player),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放页背景：封面糊开垫底 + 这首歌主色的渐变蒙层，整页跟着歌变色。
/// 用 96px 的小图放大再糊，比全尺寸模糊便宜得多，看上去的颜色一样。
class _Backdrop extends StatelessWidget {
  final String? pic;
  final Color? tint;
  const _Backdrop({required this.pic, required this.tint});

  @override
  Widget build(BuildContext context) {
    final base = tint ?? const Color(0xFF4A4A4A);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF161616)),
          if (pic != null)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: CachedNetworkImage(
                imageUrl: artUrl(pic, px: 200)!,
                httpHeaders: artHeaders,
                fit: BoxFit.cover,
                memCacheWidth: 96,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  base.withValues(alpha: .68),
                  base.withValues(alpha: .85),
                  Colors.black.withValues(alpha: .92),
                ],
                stops: const [0, .45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Vinyl-style cover: the record turns while the track plays.
class _Disc extends StatelessWidget {
  final Animation<double> spin;
  final Song song;
  const _Disc({required this.spin, required this.song});

  @override
  Widget build(BuildContext context) {
    final disc = artUrl(song.pic, px: 400);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: AspectRatio(
        aspectRatio: 1,
        child: Center(
          child: AnimatedBuilder(
            animation: spin,
            builder: (context, child) => Transform.rotate(angle: spin.value * 6.2831853, child: child),
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black, boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 18, offset: const Offset(0, 8)),
              ]),
              padding: const EdgeInsets.all(10),
              child: ClipOval(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [const Color(0xFF2A2A2A), Colors.black], stops: const [0.55, 1]),
                      ),
                      child: disc == null
                          ? const Icon(Icons.music_note, color: Colors.white24, size: 60)
                          : Padding(
                              padding: const EdgeInsets.all(26),
                              child: CachedNetworkImage(
                                imageUrl: disc,
                                httpHeaders: artHeaders,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => const Icon(Icons.music_note, color: Colors.white24, size: 60),
                              ),
                            ),
                    ),
                    Center(
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: const BoxDecoration(color: Color(0xFF111111), shape: BoxShape.circle),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricView extends StatefulWidget {
  final PlayerService player;
  const _LyricView({required this.player});

  @override
  State<_LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<_LyricView> {
  final ScrollController _ctrl = ScrollController();
  int _scrolledTo = -1;
  List<LyricLine>? _scrolledList;

  /// 手往上翻去看下一段词时，别立刻被自动滚动拽回当前那行。
  DateTime _resumeAutoAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const double _pad = 60;
  static const double _mainH = 34;
  static const double _transH = 20;

  static double _h(LyricLine l) => _mainH + (l.translated?.isNotEmpty == true ? _transH : 0);

  /// Sum of the rows above [idx]; matches itemExtentBuilder exactly, so the
  /// auto-scroll lands on the active line instead of drifting.
  double _offsetOf(List<LyricLine> lines, int idx) {
    var off = _pad;
    for (var i = 0; i < idx; i++) {
      off += _h(lines[i]);
    }
    return off;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _autoScroll(List<LyricLine> lines, int idx) {
    if (!identical(_scrolledList, lines)) {
      // 换了一首歌的歌词，上一首滚到第几行就不算数了：不重置的话，
      // 新歌恰好从同一行号开始时时灵时不灵地不跟着走。
      _scrolledList = lines;
      _scrolledTo = -1;
    }
    if (idx < 0 || !_ctrl.hasClients || idx == _scrolledTo) return;
    if (DateTime.now().isBefore(_resumeAutoAt)) return;
    _scrolledTo = idx;
    final viewport = _ctrl.position.viewportDimension;
    final target = (_offsetOf(lines, idx) - viewport / 2 + _h(lines[idx]) / 2)
        .clamp(0.0, _ctrl.position.maxScrollExtent)
        .toDouble();
    _ctrl.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    // 歌词只在「换到下一行」那一刻需要重画。以前外面包了一层 positionStream 的
    // StreamBuilder：播放器每两百毫秒推一次位置，整屏歌词就跟着排一次，几百行的
    // 歌词页上看得见卡顿。select 之后只有行号、歌词本身或加载状态变了才重建这段。
    final view = context.select<PlayerService, (List<LyricLine>, int, bool, bool)>(
        (p) => (p.lyric, p.lyricIndex, p.lyricBusy, p.busy));
    final lines = view.$1;
    final idx = view.$2;
    if (lines.isEmpty) {
      if (view.$3 || view.$4) {
        return const Center(child: Text('歌词加载中…', style: TextStyle(color: Colors.white38)));
      }
      return GestureDetector(
        onTap: player.reloadLyric,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('暂无歌词', style: TextStyle(color: Colors.white38)),
              SizedBox(height: 6),
              Text('点一下重新找', style: TextStyle(color: Colors.white30, fontSize: 11)),
            ],
          ),
        ),
      );
    }
    _autoScroll(lines, idx);
    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        // 真手势才会发 UserScrollNotification，程序里的 animateTo 不会，
        // 所以不用区分这一划是不是自动滚动自己引起的。
        if (n.metrics.axis == Axis.vertical) {
          _resumeAutoAt = DateTime.now().add(const Duration(seconds: 5));
        }
        return false;
      },
      child: ListView.builder(
        controller: _ctrl,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: _pad),
        itemExtentBuilder: (i, _) => _h(lines[i]),
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final active = i == idx;
          final trans = lines[i].translated;
          return GestureDetector(
            onTap: () {
              player.seek(player.lyricPosition(i));
              // 点这一行就是想从这里开始跟着走，别再压着自动滚动。
              _resumeAutoAt = DateTime.fromMillisecondsSinceEpoch(0);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  lines[i].text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white38,
                    fontSize: active ? 17 : 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (trans != null && trans.isNotEmpty)
                  Text(
                    trans,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: active ? Colors.white70 : Colors.white24,
                      fontSize: active ? 13 : 11.5,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 定时关闭 / 均衡器 / 播放设置, kept out of the crowded top row.
class _MoreMenu extends StatelessWidget {
  final PlayerService player;
  const _MoreMenu({required this.player});

  static const List<int> _minutes = [15, 30, 45, 60];

  @override
  Widget build(BuildContext context) {
    final active = player.sleepActive;
    return PopupMenuButton<String>(
      offset: const Offset(0, 44),
      color: const Color(0xFF2C2C2C),
      icon: const Icon(Icons.more_horiz, color: Colors.white70, size: 26),
      tooltip: '更多',
      itemBuilder: (_) => [
        if (active)
          PopupMenuItem<String>(
            value: 'sleep-off',
            child: Text('取消定时（剩余 ${_fmtLeft(player.sleepRemaining)}）',
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          )
        else
          ..._minutes.map((m) => PopupMenuItem<String>(
                value: 'sleep-$m',
                child:
                    Text('$m 分钟后停止播放', style: const TextStyle(color: Colors.white70, fontSize: 14)),
              )),
        const PopupMenuDivider(),
        for (final s in PlayerService.speeds)
          PopupMenuItem<String>(
            value: 'speed-$s',
            child: Text(
              '${s == 1.0 ? '原速' : '${s}x 倍速'}${s == player.speed ? ' ·当前' : ''}',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
            value: 'versions',
            child: Text('找其他版本', style: TextStyle(color: Colors.white70, fontSize: 14))),
        const PopupMenuItem<String>(
            value: 'eq',
            child: Text('均衡器', style: TextStyle(color: Colors.white70, fontSize: 14))),
        const PopupMenuItem<String>(
            value: 'settings',
            child: Text('播放设置', style: TextStyle(color: Colors.white70, fontSize: 14))),
      ],
      onSelected: (v) {
        if (v == 'sleep-off') {
          player.cancelSleepTimer();
        } else if (v.startsWith('sleep-')) {
          player.setSleepTimer(Duration(minutes: int.parse(v.substring(6))));
        } else if (v.startsWith('speed-')) {
          unawaited(player.setSpeed(double.parse(v.substring(6))));
        } else if (v == 'versions') {
          final song = player.current;
          if (song != null) {
            unawaited(showOtherVersionsSheet(context, song));
          }
        } else if (v == 'eq') {
          unawaited(Navigator.push(context, MaterialPageRoute(builder: (_) => const EqPage())));
        } else if (v == 'settings') {
          unawaited(Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())));
        }
      },
    );
  }
}

class _Controls extends StatelessWidget {
  final PlayerService player;
  const _Controls({required this.player});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SeekBar(player: player),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: Icon(player.playModeIcon, color: Colors.white70, size: 24),
                tooltip: player.playModeLabel,
                onPressed: player.cyclePlayMode,
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 32),
                onPressed: () => player.previous(),
              ),
              StreamBuilder<bool>(
                stream: player.playingStream,
                builder: (context, s) => GestureDetector(
                  onTap: () => player.togglePlay(),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
                    child: Icon(s.data == true ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 32),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 32),
                onPressed: () => player.next(),
              ),
              IconButton(
                icon: const Icon(Icons.queue_music, color: Colors.white70, size: 24),
                tooltip: '播放队列',
                onPressed: () => showPlayQueue(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _fmt(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// 进度条。拖动时只移动拇指并预览时间，松手才真正 seek ——
/// 每次 onChanged 都 seek 会让解码器反复重建，拖起来又卡又不准。
class _SeekBar extends StatefulWidget {
  final PlayerService player;
  const _SeekBar({required this.player});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  int? _dragMs;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, snapshot) {
        final total = widget.player.duration ?? Duration.zero;
        final maxMs = total.inMilliseconds;
        final shown = _dragMs ?? (snapshot.data ?? Duration.zero).inMilliseconds;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Text(_fmt(Duration(milliseconds: shown.clamp(0, maxMs > 0 ? maxMs : 0))),
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(
                      trackHeight: 2,
                      thumbColor: AppTheme.primaryLight,
                      activeTrackColor: AppTheme.primaryLight,
                      inactiveTrackColor: Colors.white24),
                  child: Slider(
                    value: maxMs == 0 ? 0 : shown.clamp(0, maxMs).toDouble(),
                    max: maxMs.toDouble(),
                    onChanged: maxMs == 0 ? null : (v) => setState(() => _dragMs = v.round()),
                    onChangeEnd: maxMs == 0
                        ? null
                        : (v) {
                            setState(() => _dragMs = null);
                            widget.player.seek(Duration(milliseconds: v.round()));
                          },
                  ),
                ),
              ),
              Text(_fmt(total), style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        );
      },
    );
  }
}
