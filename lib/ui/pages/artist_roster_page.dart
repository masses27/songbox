import 'package:flutter/material.dart';

import '../../library/library_store.dart';
import '../../library/roster_store.dart';
import '../../models/results.dart';
import '../../util/fuzzy_query.dart';
import '../../util/humanize.dart';
import '../../util/roster.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist_page.dart';
import 'builtin_library.dart';
import 'search_page.dart';

/// 一格标题与一行歌手在竖排里各占多高。右侧索引条跳过去要的偏移量是这两个数加出来的，
/// 所以这两格都由 SizedBox 钉死，不让内容自己撑（撑高了一位，索引条就跳歪一格）。
const _headerExtent = 34.0;
const _rowExtent = 64.0;

/// 明星名单：A–Z 一格一格排下来，就地筛词，点一行进歌手页。
///
/// 为什么单开一页：搜索页那一栏「歌手」要她先知道名字，而按字母翻是另一种找法 ——
/// 记得那谁唱过什么、名字却在嘴边。名单从网易云一格一格拉（每格 100 位、一共 2700 位），
/// 拉回来存本机，下次点进来先有屏、旧了才补新的。
class ArtistRosterPage extends StatefulWidget {
  const ArtistRosterPage({super.key, this.fetch, this.store});

  /// 一格的取法，默认走 [BuiltinLibrary.rosterBucket]。测试递假货进来 ——
  /// 没有这颗口子的话，这一页在离线测试里连一屏人都摆不上屏，那条索引条跳得准不准
  /// 就只能在真机上看。
  final Future<List<ArtistInfo>> Function(String letter)? fetch;

  /// 名单落到哪。默认是本机的 `roster/artists.json`，测试给一个临时目录。
  final RosterStore? store;

  @override
  State<ArtistRosterPage> createState() => _ArtistRosterPageState();
}

class _ArtistRosterPageState extends State<ArtistRosterPage> {
  late final RosterStore _store = widget.store ?? RosterStore();
  final _filter = TextEditingController();
  final _scroll = ScrollController();

  Map<String, List<ArtistInfo>> _buckets = const {};

  /// 这一遍拉到了第几格 / 一共几格。只在转圈那几秒用来报进度。
  int _passDone = 0;
  int _passTotal = 0;
  bool _loading = false;
  DateTime? _fetchedAt;

  /// 写盘失败那句原因。存不住不影响这次看名单，但下一次点进来就得重打，
  /// 这件事得让她看见，不能像以前那样一句都不吭。
  String? _saveNote;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final snap = await _store.load();
    if (snap != null && mounted) {
      setState(() {
        _buckets = snap.buckets;
        _fetchedAt = snap.fetchedAt;
      });
      // 七天以内的那份直接用，一个请求都不发；旧了才在屏后补打一遍。
      if (snap.fresh()) return;
    }
    await _pass(rosterLetters);
  }

  /// 拉一批格子。首屏是全部 27 格，「再拉一遍」只补还缺着的那几格。
  /// 每一格到手就上屏：实测整批不到一秒，但头一格八十来毫秒就能点，没必要等那一秒。
  Future<void> _pass(Iterable<String> letters, {bool force = false}) async {
    if (_loading) return;
    final list = letters.toList();
    if (list.isEmpty) return;
    setState(() {
      _loading = true;
      _passDone = 0;
      _passTotal = list.length;
    });
    final lib = BuiltinLibrary.instance;
    // 下拉刷新要清掉 5 分钟目录缓存，否则 Memo 会把上一批原样递回来，刷了等于没刷。
    if (force) lib.invalidateCatalog();
    final load = await loadRoster(
      widget.fetch ?? lib.rosterBucket,
      onBucket: (letter, artists) {
        if (!mounted) return;
        setState(() {
          _passDone++;
          if (artists.isNotEmpty) _buckets = {..._buckets, letter: artists};
        });
      },
    );
    if (!mounted) return;
    final merged = Map<String, List<ArtistInfo>>.from(_buckets);
    setState(() {
      _loading = false;
      if (load.buckets.isNotEmpty) _fetchedAt = DateTime.now();
      _saveNote = null;
    });
    if (merged.isNotEmpty) {
      final err = await _store.save(merged);
      if (mounted && err != null) setState(() => _saveNote = err);
    }
  }

  void _retryMissing() {
    final missing = missingBuckets(_buckets);
    if (missing.isNotEmpty) _pass(missing);
  }

  @override
  Widget build(BuildContext context) {
    final kw = normalizeKeyword(_filter.text);
    final filtering = kw.isNotEmpty;
    final groups = rosterGroups(_buckets, keyword: _filter.text);
    final shown = rosterCount(groups);
    final onScreen = _buckets.values.fold(0, (s, v) => s + v.length);
    final failed = missingBuckets(_buckets);

    // 摊平成一竖排：标题行 + 这一格的人。顺手记下每个字母的顶部偏移给索引条用。
    final items = <Object>[];
    final extents = <double>[];
    final letterTops = <String, double>{};
    var acc = 0.0;
    for (final g in groups) {
      letterTops[g.letter] = acc;
      items.add(g);
      extents.add(_headerExtent);
      acc += _headerExtent;
      for (final a in g.artists) {
        items.add(a);
        extents.add(_rowExtent);
        acc += _rowExtent;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(filtering ? '名单筛「$kw」' : '明星名单')),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: Column(
        children: [
          _filterField(filtering),
          _noteLine(filtering: filtering, shown: shown, onScreen: onScreen, failed: failed),
          Expanded(
            child: Stack(
              children: [
                if (items.isEmpty)
                  RefreshIndicator(
                    onRefresh: () => _pass(rosterLetters, force: true),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [_blankBlock(filtering, kw, onScreen, failed)],
                    ),
                  )
                else
                  RefreshIndicator(
                    onRefresh: () => _pass(rosterLetters, force: true),
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverVariedExtentList.builder(
                          itemCount: items.length,
                          itemExtentBuilder: (i, _) => extents[i],
                          itemBuilder: (context, i) {
                            final it = items[i];
                            return it is RosterGroup
                                ? _LetterHeader(group: it, filtering: filtering)
                                : _ArtistRow(artist: it as ArtistInfo);
                          },
                        ),
                      ],
                    ),
                  ),
                if (!filtering && groups.isNotEmpty)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: _IndexBar(
                      letters: [for (final g in groups) g.letter],
                      onPick: (letter) {
                        final top = letterTops[letter];
                        if (top == null || !_scroll.hasClients) return;
                        _scroll.jumpTo(top.clamp(0.0, _scroll.position.maxScrollExtent));
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterField(bool filtering) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.pillBg,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            controller: _filter,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: '在名单里找：名字或别名',
              hintStyle: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              border: InputBorder.none,
              isDense: true,
              icon:
                  Icon(Icons.filter_alt_outlined, size: 20, color: AppTheme.textSecondary),
              suffixIcon: filtering
                  ? IconButton(
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      tooltip: '清空',
                      icon: Icon(Icons.close, color: AppTheme.textSecondary),
                      onPressed: () {
                        _filter.clear();
                        setState(() {});
                      },
                    )
                  : null,
            ),
          ),
        ),
      );

  /// 列表上面那一行小字：转圈时报进度，筛的时候报两个数，缺格时报缺哪几格。
  Widget _noteLine({
    required bool filtering,
    required int shown,
    required int onScreen,
    required List<String> failed,
  }) {
    final List<String> lines = [];
    if (_loading) {
      lines.add(rosterProgressNote(done: _passDone, total: _passTotal, loaded: onScreen));
    } else if (filtering) {
      lines.add('筛出 $shown 位 · 屏上这一份共 $onScreen 位');
    } else if (failed.isNotEmpty) {
      lines.add(rosterPartialNote(failed: failed, loaded: onScreen));
    } else {
      final when = _fetchedAt == null ? '' : ' · ${LibraryStore.dayLabel(_fetchedAt!.millisecondsSinceEpoch)}拉的';
      lines.add('共 $onScreen 位 · 每个字母前 $rosterBucketSize 位$when');
    }
    if (_saveNote != null) lines.add('名单这次没存进本机：${_saveNote!}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Text(l, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          if (!_loading && failed.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _retryMissing,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('再拉一遍缺的那几格', style: TextStyle(fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }

  /// 屏上一位都没有时那一大块。要分清「没答话」和「真没有」：
  /// 27 格全空是接口那头没回话，不是这片曲库一个歌手都没有。
  Widget _blankBlock(bool filtering, String kw, int onScreen, List<String> failed) {
    if (_loading && onScreen == 0) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 60, 24, 32),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (filtering) {
      return _Blank(
        icon: Icons.person_search_outlined,
        message: '屏上这 $onScreen 位里没对上「$kw」\n'
            '名单只有每个字母前 $rosterBucketSize 位，网易云那头还能接着搜（拼音也认）',
        actions: [
          _BlankAction('搜歌手', () => SearchPage.open(context, kw, kind: 1)),
          _BlankAction('在歌里搜这个词', () => SearchPage.open(context, kw)),
          _BlankAction('清空，看全部名单', () {
            _filter.clear();
            setState(() {});
          }),
        ],
      );
    }
    if (onScreen > 0) {
      // 屏上有东西就不说「没有」：这一格空是筛出来的，不是名单空了。
      return EmptyState(message: '筛完一位都不剩 · 清空上面那行就看得到 $onScreen 位');
    }
    return _Blank(
      icon: Icons.cloud_off,
      message: failed.length >= rosterLetters.length
          ? '名单一格也没拉回来 · 多半是这会儿没网'
          : '名单还没拉回来 · 再拉一遍',
      actions: [_BlankAction('再拉一遍', () => _pass(rosterLetters, force: true))],
    );
  }
}

class _LetterHeader extends StatelessWidget {
  final RosterGroup group;
  final bool filtering;
  const _LetterHeader({required this.group, required this.filtering});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _headerExtent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(group.label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Text(filtering ? '筛出 ${group.count}' : '${group.count} 位',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  final ArtistInfo artist;
  const _ArtistRow({required this.artist});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (artist.alias.isNotEmpty) artist.alias,
      if (artist.musicSize > 0) '${fmtCount(artist.musicSize)} 首歌',
      if (artist.albumSize > 0) '${fmtCount(artist.albumSize)} 张专辑',
    ];
    return SizedBox(
      height: _rowExtent,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ArtistPage(artistId: artist.id, seedName: artist.name)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              ClipOval(
                child: CoverTile(
                    label: '',
                    imageUrl: artist.pic,
                    size: 46,
                    icon: Icons.person_outline,
                    seedText: artist.name),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(artist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, color: AppTheme.textPrimary)),
                    if (parts.isNotEmpty)
                      Text(parts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右边那一竖条字母：点一下跳到那一格，按住上下拖就在屏上滑。
///
/// 只摆屏上真有的格子：某一格没拉回来时它不该在条上，否则点下去原地不动，
/// 看起来像是这条坏了。
class _IndexBar extends StatelessWidget {
  final List<String> letters;
  final void Function(String letter) onPick;
  const _IndexBar({required this.letters, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 4, 6),
          child: LayoutBuilder(
            builder: (context, inner) {
              // 一格多高按扣掉上下衬距之后的可用高度分，27 个字母加起来正好铺满这一条；
              // 屏矮一点，字就跟着缩（FittedBox 保底不溢出），不会顶出红黑条。
              final step = inner.maxHeight / letters.length;
              void pick(double dy) {
                final i = (dy / step).floor().clamp(0, letters.length - 1);
                onPick(letters[i]);
              }

              return GestureDetector(
                key: const Key('rosterIndexBar'),
                behavior: HitTestBehavior.translucent,
                onTapDown: (e) => pick(e.localPosition.dy),
                onVerticalDragUpdate: (e) => pick(e.localPosition.dy),
                child: SizedBox(
                  width: 16,
                  child: Column(
                    children: [
                      for (final l in letters)
                        SizedBox(
                          height: step,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(l,
                                style: TextStyle(
                                    fontSize: 10,
                                    height: 1.1,
                                    color: AppTheme.textSecondary)),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _BlankAction {
  final String label;
  final VoidCallback onTap;
  _BlankAction(this.label, this.onTap);
}

/// [EmptyState] 只带一颗按钮；「没对上词」那一屏要给两条路（搜歌手 / 搜歌），
/// 所以这里自己摆一行按钮。
class _Blank extends StatelessWidget {
  final IconData icon;
  final String message;
  final List<_BlankAction> actions;
  const _Blank({required this.icon, required this.message, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppTheme.textSecondary),
          const SizedBox(height: 10),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final a in actions)
                OutlinedButton(
                  onPressed: a.onTap,
                  child: Text(a.label, style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
