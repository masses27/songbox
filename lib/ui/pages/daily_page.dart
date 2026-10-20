import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builtin_library.dart';

/// 今日私荐 — 每天从推荐池里稳定抽一批，早上看到的和晚上看到的是同一份，
/// 但第二天会自己换。网易云「每日推荐」的用法，只是不需要登录。
class DailyPage extends StatefulWidget {
  const DailyPage({super.key});

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  List<Song> _today = const [];
  bool _loading = false;
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
      // 下拉刷新要绕过 5 分钟目录缓存，否则拉出来的还是缓存里那一批。
      if (refresh) BuiltinLibrary.instance.invalidateCatalog();
      final pool = await BuiltinLibrary.instance.recommendedSongs(limit: 30);
      if (!mounted) return;
      setState(() => _today = pickToday(pool));
    } catch (e) {
      if (mounted) setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final date = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日私荐'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text('${date.month}月${date.day}日 · 每天换一批，收藏了就存进歌单',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
                if (_today.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => player.playList(_today, 0),
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: const Text('播放全部', style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
        ),
      ),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: Builder(
        builder: (context) {
          if (_loading && _today.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_today.isEmpty) {
            return EmptyState(
              message: _error == null ? '今天没荐出歌来，下拉再试一次' : '推荐没拉到：$_error',
              icon: Icons.auto_awesome,
              actionText: '重新加载',
              onAction: () => _load(refresh: true),
            );
          }
          return RefreshIndicator(
            onRefresh: () => _load(refresh: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (var i = 0; i < _today.length; i++)
                  SongListRow(
                    song: _today[i],
                    number: i + 1,
                    siblings: _today,
                    active: context.select<PlayerService, bool>((p) => p.isCurrent(_today[i])),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text('这批歌按日期抽，换一天再进来就是另一批。',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Date-seeded shuffle so the same day always yields the same picks. A random
/// pool order on every rebuild would make the list jump around under setState.
List<Song> pickToday(List<Song> pool, {int count = 12, DateTime? at}) {
  if (pool.length <= count) return List.of(pool);
  final d = at ?? DateTime.now();
  final rnd = Random(d.year * 372 + d.month * 31 + d.day);
  final picks = List.of(pool);
  for (var i = picks.length - 1; i > 0; i--) {
    final j = rnd.nextInt(i + 1);
    final t = picks[i];
    picks[i] = picks[j];
    picks[j] = t;
  }
  return picks.sublist(0, count);
}
