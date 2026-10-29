import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../library/library_store.dart';
import '../../models/song.dart';
import '../../player/player_service.dart';
import '../../util/app_log.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../rank_groups.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builtin_library.dart';

/// 今日私荐 — 按她本机听出来的口味，从当天的公共池子里挑一批。
///
/// 没有登录，也没有平台账号，所以「私荐」这两个字只可能靠听歌记录本身兑现：
/// 收藏、自建歌单、每首歌播过几次、有没有听完（见 Taste 那一层）。口味还没听出来的
/// 时候退回原来的做法 —— 按日期从池子里稳定抽一批，第二天自己换。
class DailyPage extends StatefulWidget {
  const DailyPage({super.key});

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  List<Song> _today = const [];

  /// 这批歌是按哪几位歌手挑的，空表示还在用日期抽。
  List<String> _why = const [];
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
      final taste = LibraryStore.instance.taste();
      final news = await BuiltinLibrary.instance.recommendedSongs(limit: 30);
      // 30 首新歌这个池子太浅，口味在里面挑不出东西：有余力就把官方主榜倒进来。
      final pool = taste.isEmpty ? news : [...news, ...await _rankPool()];
      if (!mounted) return;
      setState(() {
        // 已经找到免费版的会员歌不该再被口味引擎压档：那些一按就出声。
        _today = taste.rank(pool, count: 12, swapReady: LibraryStore.instance.hasSwapSong);
        _why = taste.isEmpty ? const [] : taste.topArtists(2);
      });
      AppLog.add('荐', '今日私荐 ${_today.length} 首（池子 ${pool.length} 首）'
          '${_why.isEmpty ? '：还没听出口味，按日期抽' : '：按 ${_why.join('、')} 挑'}');
    } catch (e) {
      AppLog.add('荐', '今日私荐没拉到：${humanizeError(e)}');
      if (mounted) setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 榜单拿不到就算了：口味照样能在剩下的池子里挑，只是准头差一点，
  /// 不该因为一个榜挂了整页就报错。
  Future<List<Song>> _rankPool() async {
    try {
      final ranks = homeRanks(await BuiltinLibrary.instance.rankList('wy'));
      final pages = await Future.wait([
        for (final r in ranks.take(2)) BuiltinLibrary.instance.rankSongs(r.source, r.id),
      ]);
      return [for (final p in pages) ...p.list];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerService>();
    final date = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日私荐'),
        // 桌面上这一颗是这一页唯一的刷新入口：鼠标拖不动下拉刷新，
        // 而空页那句「下拉再试一次」在电脑上根本做不到。
        actions: [DesktopRefreshButton(onRefresh: () => _load(refresh: true), busy: _loading)],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(_subtitle(date),
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
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: Builder(
          builder: (context) {
            if (_loading && _today.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [SizedBox(height: 160), Center(child: CircularProgressIndicator())],
              );
            }
            if (_today.isEmpty) {
              // 这一支也得能下拉：那句话写着「下拉再试一次」，可原来下拉只在有歌的
              // 时候才挂得上，空页面上怎么拉都没有反应。
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  EmptyState(
                    message: _error == null ? '今天没荐出歌来，下拉再试一次' : '推荐没拉到：$_error',
                    icon: Icons.auto_awesome,
                    actionText: '重新加载',
                    onAction: () => _load(refresh: true),
                  ),
                ],
              );
            }
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (var i = 0; i < _today.length; i++)
                  SongListRow(
                    song: _today[i],
                    number: i + 1,
                    siblings: _today,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    _why.isEmpty
                        ? '这批歌按日期抽，换一天再进来就是另一批。多听几首、收藏几首，下一次进来就照你听出来的口味挑。'
                        : '照你最近听过的 ${_why.join('、')} 挑的，换一天再进来会换一批。',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _subtitle(DateTime date) {
    final day = '${date.month}月${date.day}日';
    if (_why.isEmpty) return '$day · 每天换一批，收藏了就存进歌单';
    // 把「为什么是这几首」写在脸上：口味是她听出来的，这句话才是这一页的证据。
    return '$day · 按你听过的 ${_why.join('、')} 挑的';
  }
}
