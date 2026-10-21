import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../download/download_manager.dart';
import '../library/library_store.dart';
import '../models/results.dart';
import '../models/song.dart';
import '../player/player_service.dart';
import '../settings/app_settings.dart';
import '../util/art_url.dart';
import '../util/humanize.dart';
import 'pages/builtin_library.dart';
import 'theme.dart';

/// Shared NetEase-Cloud-Music-style building blocks.

/// 来源码给人看的名字。界面上到处是 wy/kw，用户没见过的只会当成乱码。
String sourceLabel(String source) => switch (source) {
      'wy' => '网易云',
      'kw' => '酷我',
      'tx' => 'QQ',
      'bl' => 'B 站',
      _ => source,
    };

/// 这一首在这台手机上**实际**能听到的档位。
///
/// 设置里那一档是「想要」，不是「拿得到」：匿名出整首的那两条各有上限
/// （B 站 192k、QQ 128k），会员墙后面靠它们兜底的歌永远到不了无损。以前播放页
/// 和下载弹窗都直接写设置值，于是「无损 flac · 免费版」挂在耳朵是 192k 那儿 ——
/// 换源本来就看不见摸不着，标注再骗人，她更不会信这功能是真是的。
String heardQuality(String wanted, String source) {
  final cap = switch (source) {
    'bl' => '192k',
    'tx' => '128k',
    _ => null,
  };
  if (cap == null) return wanted;
  const order = ['128k', '192k', '320k', 'flac'];
  return order.indexOf(cap) < order.indexOf(wanted) ? cap : wanted;
}

/// Rounded pill search bar shown at the top of 首页/发现.
class NetEaseSearchBar extends StatelessWidget {
  final String hint;
  final VoidCallback onTap;
  const NetEaseSearchBar({super.key, this.hint = '搜索音乐、歌手、歌词', required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.pillBg,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.search, size: 20, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(hint, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// Section header with title + optional trailing action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionText;
  final VoidCallback? onAction;
  const SectionHeader(this.title, {super.key, this.actionText, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 12, 8),
      child: Row(
        children: [
          Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const Spacer(),
          if (actionText != null)
            GestureDetector(
              onTap: onAction,
              child: Row(
                children: [
                  Text(actionText!, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A gradient cover placeholder used until real artwork is wired in.
class CoverTile extends StatelessWidget {
  final String label;
  final String? imageUrl;
  final IconData icon;
  final double size;

  /// 没封面时渐变按什么取色。列表行旁边已经写了名字、不想在图上再叠一遍文字的，
  /// 用这个传个取色种子进来，免得一整排占位色块全一个颜色。
  final String seedText;
  const CoverTile(
      {super.key,
      required this.label,
      this.imageUrl,
      this.icon = Icons.music_note,
      this.size = 100,
      this.seedText = ''});

  @override
  Widget build(BuildContext context) {
    // 渐变按歌名取色：这些卡片传进来的 label 是空的，不取封面地址的话
    // 一整屏占位色块会一模一样，看起来像是坏掉了。
    final seed = seedText.isNotEmpty
        ? seedText
        : (label.isNotEmpty ? label : (imageUrl ?? ''));
    final hue = (seed.codeUnits.fold<int>(0, (a, b) => a + b) * 37) % 360;
    // 轮播那种 size = double.infinity 的写法要按屏幕宽来要图，否则 round() 溢出，
    // 只会拿回一张 120px 的小图糊在大块上。
    final side = size.isFinite ? size : MediaQuery.sizeOf(context).width;
    final px = (side * MediaQuery.devicePixelRatioOf(context)).round().clamp(1, 1200);
    final art = artUrl(imageUrl, px: px);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.6).toColor(), HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.45).toColor()],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (art != null)
            CachedNetworkImage(
              imageUrl: art,
              httpHeaders: artHeaders,
              memCacheWidth: px,
              memCacheHeight: px,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            )
          else
            Padding(
              padding: const EdgeInsets.all(10),
              // size 可能是 infinity（轮播图），图标得按有限值算，否则布局会炸。
              child: Icon(icon, color: Colors.white70, size: (side.isFinite ? side : 130.0) * 0.32),
            ),
          if (label.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]),
                ),
                child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Playlist card: real cover plus name and a one-line description.
class CoverCard extends StatelessWidget {
  final SheetInfo sheet;
  const CoverCard({super.key, required this.sheet});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 108,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverTile(label: '', imageUrl: sheet.img, size: 108),
          const SizedBox(height: 4),
          Text(sheet.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, height: 1.25)),
          // 播放量 helps picking a 歌单 blind: 「经典老歌」有 8 个，热的那个一眼就能看出来。
          if (sheet.playCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${fmtCount(sheet.playCount)}次播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
        ],
      ),
    );
  }
}

/// Generic empty / failure block with an optional retry action.
class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? actionText;
  final VoidCallback? onAction;
  const EmptyState({super.key, required this.message, this.icon = Icons.sentiment_dissatisfied_outlined, this.actionText, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppTheme.textSecondary),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          if (actionText != null) ...[
            const SizedBox(height: 12),
            ElevatedButton(onPressed: onAction, child: Text(actionText!)),
          ],
        ],
      ),
    );
  }
}

/// 「会员专享」角标。网易云列表里也是这样提前标出来的：点开之前就知道这首八成
/// 要换版本，比播到一半弹一句「取不到完整音频」好受得多。
class VipBadge extends StatelessWidget {
  /// 已经替她找到免费版本时改口「免费版」，不然角标一直写着 VIP，
  /// 她以为这首还是要撞墙。
  final bool ready;
  const VipBadge({super.key, this.ready = false});

  @override
  Widget build(BuildContext context) {
    final tone = ready ? (AppTheme.dark ? Colors.tealAccent : Colors.teal) : AppTheme.vipGold;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: AppTheme.dark ? .16 : .12),
        border: Border.all(color: tone.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(3, 2, 3, 2),
        child: Text(ready ? '免费版' : 'VIP',
            style: TextStyle(
                fontSize: 9,
                height: 1,
                letterSpacing: .3,
                fontWeight: FontWeight.w700,
                color: tone)),
      ),
    );
  }
}

/// 底部标签「再点一次回到顶部」——网易云也是这样。壳层只负责把这次点击通知到
/// 当前页，各页用自己的 ScrollController 决定怎么回。
abstract class ScrollToTop {
  void scrollToTop();
}

/// 列表页的「会员歌体检」条。
///
/// 一首一首撞会员墙太慢了：每首都要跑完整条二十多秒的尝试链，40 首的热单能卡半天。
/// 这里把整单一次交给后台批量处理，结果落盘，下次播到那首第一步就命中。
class VipScanBar extends StatefulWidget {
  final List<Song> songs;
  const VipScanBar({super.key, required this.songs});

  @override
  State<VipScanBar> createState() => _VipScanBarState();
}

class _VipScanBarState extends State<VipScanBar> {
  bool _running = false;
  int _done = 0;
  String? _result;

  @override
  void didUpdateWidget(covariant VipScanBar old) {
    super.didUpdateWidget(old);
    // 翻页把列表拉长了，之前那句结论就不完整，撤掉重算。
    if (old.songs.length != widget.songs.length) _result = null;
  }

  Future<void> _scan() async {
    if (_running) return;
    setState(() {
      _running = true;
      _done = 0;
      _result = null;
    });
    try {
      final r = await BuiltinLibrary.instance.scanVipSongs(widget.songs, onProgress: (d, _) {
        if (mounted) setState(() => _done = d);
      });
      if (!mounted) return;
      setState(() => _result = r.total == 0
          ? '这里的会员歌都已经处理过了'
          : '${r.fixed} 首已备好免费版 · ${r.dead} 首确实没有');
    } catch (e) {
      if (mounted) setState(() => _result = '体检没跑完：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final vip = widget.songs.where((s) => s.needsVip).length;
    // 一首会员歌都没有就不用提这一行。
    if (vip == 0) return const SizedBox.shrink();
    final ready = store.vipReadyCount(widget.songs);
    final todo = store.vipNeedScan(widget.songs).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _running
                  ? '正在后台找免费版… $_done / $todo'
                  : _result ??
                      '这一屏 $vip 首会员专享'
                          '${ready > 0 ? '，已备好 $ready 首免费版' : ''}'
                          '${todo > 0 ? '，$todo 首还没找过' : ''}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          if (_running)
            const SizedBox(
                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          // 体检按下去会连着发几十次搜索，一首一首撞墙时她随时可以反悔，
          // 但整单跑完（todo==0）就没必要再按了。
          else if (todo > 0)
            TextButton(
                onPressed: _scan,
                child: const Text('整单找免费版', style: TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// The one song row every list shares: 序号或封面 + 名称/歌手 + 时长 + ♥ + ⋮.
/// Tapping plays inside the surrounding list; long press opens the same actions
/// as the ⋮ button, which is how 网易云 keeps 收藏/下一首播放/下载 within reach.
class SongListRow extends StatelessWidget {
  final Song song;

  /// When set, the leading slot shows this rank number instead of the cover.
  final int? number;

  /// The list this row belongs to — used for the default "play from here".
  final List<Song>? siblings;
  final VoidCallback? onTap;

  /// Shown before the ♥ — used by 我的 页 to put a 移出列表 button on a row.
  final Widget? extraTrailing;
  const SongListRow({
    super.key,
    required this.song,
    this.number,
    this.siblings,
    this.onTap,
    this.extraTrailing,
  });

  @override
  Widget build(BuildContext context) {
    // 只订阅自己这一行的收藏状态：watch<LibraryStore>() 会让整列表在
    // 任意收藏/最近播放变化时重建。
    final fav = context.select<LibraryStore, bool>((s) => s.isFavorite(song));
    // 「正在播的这一首」同理。以前由列表算好传进来：那些列表都是父级一个 context
    // 里循环 select 的，一次切歌要么整列表重建，要么标记落在别的行为上——几百首的歌单
    // 每几秒整表重建一次，滚动时看得见掉帧。
    final active = context.select<PlayerService, bool>((p) => p.isCurrent(song));
    final store = LibraryStore.instance;
    final sub = [
      song.singer,
      if (song.albumName?.isNotEmpty == true) song.albumName!,
    ].join('  ·  ');
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: number == null
          ? _Cover(song: song, active: active)
          : SizedBox(
              width: 26,
              child: Text(
                '$number',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? AppTheme.primary : AppTheme.textSecondary,
                  fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
      title: Text(
        song.name.isEmpty ? '未知歌曲' : song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14.5,
          color: active ? AppTheme.primary : AppTheme.textPrimary,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        sub,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extraTrailing,
          if (song.needsVip)
            Padding(padding: const EdgeInsets.only(right: 5), child: VipBadge(ready: store.hasSwapSong(song))),
          if (store.hasLocalFile(song))
            Padding(
              padding: EdgeInsets.only(right: 2),
              child: Icon(Icons.offline_pin_outlined, size: 15, color: AppTheme.textSecondary),
            ),
          if ((song.interval ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(formatPlayTime(song.interval),
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          IconButton(
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40),
            padding: EdgeInsets.zero,
            tooltip: fav ? '取消收藏' : '收藏',
            onPressed: () {
              store.toggleFavorite(song);
              if (fav) {
                // 取消是最容易误触的一半，留个撤销。
                toast(context, '已取消收藏',
                    actionLabel: '撤销', onAction: () => store.toggleFavorite(song));
              }
            },
            icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                color: fav ? AppTheme.primary : AppTheme.textSecondary),
          ),
          IconButton(
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 38),
            padding: EdgeInsets.zero,
            tooltip: '更多',
            onPressed: () => showSongMenu(context, song, siblings: siblings, active: active),
            icon: Icon(Icons.more_horiz, color: AppTheme.textSecondary),
          ),
        ],
      ),
      onTap: onTap ?? () => _playHere(context),
      onLongPress: () => showSongMenu(context, song, siblings: siblings, active: active),
    );
  }

  void _playHere(BuildContext context) {
    final list = siblings;
    if (list == null) return;
    final i = list.indexOf(song);
    if (i >= 0) context.read<PlayerService>().playList(list, i);
  }
}

class _Cover extends StatelessWidget {
  final Song song;
  final bool active;
  const _Cover({required this.song, required this.active});

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final pic = artUrl(song.pic, px: px);
    if (pic == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(Icons.music_note, color: AppTheme.textSecondary),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: pic,
        httpHeaders: artHeaders,
        width: size,
        height: size,
        // 44 的行内图标按原图 300x300 解码，一屏 20 行就是几十 MB 纹理。
        memCacheWidth: px,
        memCacheHeight: px,
        fit: BoxFit.cover,
        placeholder: (_, _) => SizedBox(
            width: size, height: size, child: ColoredBox(color: AppTheme.sheetBg)),
        errorWidget: (_, _, _) =>
            const SizedBox(width: size, height: size, child: Icon(Icons.music_note)),
      ),
    );
  }
}

/// 「更多」sheet: 收藏 / 下一首播放 / 加入队列 / 下载.
Future<void> showSongMenu(BuildContext context, Song song,
    {List<Song>? siblings, bool active = false}) {
  final store = LibraryStore.instance;
  final fav = store.isFavorite(song);
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.pageBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      void rowAction(VoidCallback run) {
        Navigator.pop(ctx);
        run();
      }

      Widget item(IconData icon, String label, VoidCallback run) => ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -1),
            leading: Icon(icon, size: 22, color: AppTheme.textPrimary),
            title: Text(label, style: const TextStyle(fontSize: 15)),
            onTap: () => rowAction(run),
          );
      final player = context.read<PlayerService>();
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  if (song.needsVip) ...[
                    VipBadge(ready: LibraryStore.instance.hasSwapSong(song)),
                    const SizedBox(width: 6),
                  ],
                  if (active)
                    const Icon(Icons.equalizer_rounded, size: 18, color: AppTheme.primary),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(song.singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            ),
            Divider(height: 1, color: AppTheme.divider),
            item(fav ? Icons.favorite : Icons.favorite_border,
                fav ? '取消收藏' : '收藏', () {
              store.toggleFavorite(song);
              if (fav) {
                toast(context, '已取消收藏',
                    actionLabel: '撤销', onAction: () => store.toggleFavorite(song));
              }
            }),
            item(Icons.play_arrow, '下一首播放', () {
              final idle = player.index < 0;
              player.playNext(song);
              toast(context, idle ? '没有正在放的歌，已直接播放' : '已排到下一首');
            }),
            item(Icons.queue_music, '加入播放队列', () {
              final idle = player.index < 0;
              player.addToQueue(song);
              toast(context, idle ? '没有正在放的歌，已直接播放' : '已加到队列第 ${player.queue.length} 首');
            }),
            if (siblings != null)
              item(Icons.playlist_play, '播放该列表',
                  () => player.playList(siblings, siblings.indexOf(song))),
            item(Icons.playlist_add, '加入歌单', () => pickPlaylist(context, song)),
            item(Icons.change_circle_outlined, '找其他版本',
                () => showOtherVersionsSheet(context, song)),
            if (!store.hasLocalFile(song))
              item(Icons.download, '下载', () => requestDownload(context, song))
            else
              item(Icons.delete_outline, '删除已下载', () => deleteLocalSong(context, song)),
            const SizedBox(height: 6),
          ],
        ),
      );
    },
  );
}

/// 删掉一首下载好的歌。列表页上没有入口，只能在「我的 · 已下载」里找，
/// 长按菜单里顺手就能删。
Future<void> deleteLocalSong(BuildContext context, Song song) async {
  final ok = await confirmAction(context,
      title: '删除本地文件', message: '删除后这首歌回到在线播放，想再离线听需要重新下载。');
  if (!ok || !context.mounted) return;
  await DownloadManager.instance.deleteDownload(song);
  if (!context.mounted) return;
  toast(context, '已删除本地文件');
}

/// 「找其他版本」：一首歌卡在会员墙后面时，同一首歌在网易云往往还留着一条免费的
/// 现场版／翻唱，酷我也常有同名。自动换源不敢替（怕放错成另一首），这里让她自己挑。
Future<void> showOtherVersionsSheet(BuildContext context, Song song) async {
  final picked = await showModalBottomSheet<Song>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.pageBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _OtherVersionsSheet(song: song),
  );
  if (picked == null || !context.mounted) return;
  // 不给「换回来」：换回去的就是那首放不出的，撤销只会立刻再来一次报错。
  // 起播不 await：等它接好音频才报「已换成」，那半秒里她会以为没点上再点一次。
  context.read<PlayerService>().playInsteadOf(song, picked);
  // 她亲手挑的这条记下来：下次同一首第一步就放它，不用再撞一次墙再挑一遍。
  LibraryStore.instance.rememberSwapSong(song, picked);
  final who = picked.singer.isEmpty ? '' : ' · ${picked.singer}';
  toast(context, '已换成「${picked.name}$who」');
}

class _OtherVersionsSheet extends StatefulWidget {
  final Song song;
  const _OtherVersionsSheet({required this.song});

  @override
  State<_OtherVersionsSheet> createState() => _OtherVersionsSheetState();
}

class _OtherVersionsSheetState extends State<_OtherVersionsSheet> {
  late Future<List<Song>> _future = BuiltinLibrary.instance.otherVersions(widget.song);

  void _reload() => setState(() {
        _future = BuiltinLibrary.instance.otherVersions(widget.song);
      });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text('「${widget.song.name}」的其他版本',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                      onPressed: _reload,
                      icon: Icon(Icons.refresh, size: 20, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                widget.song.needsVip
                    ? '这首是网易云会员专享。下面是同一首歌的其他录音，点一下就用它顶上。'
                    : '现场版、翻唱、别的平台的同名。点一下换掉当前这首。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
            Divider(height: 1, color: AppTheme.divider),
            Expanded(
              child: FutureBuilder<List<Song>>(
                future: _future,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                        child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 2.4)));
                  }
                  final found = snap.data ?? const <Song>[];
                  if (found.isEmpty) {
                    return const EmptyState(
                      icon: Icons.music_off_outlined,
                      message: '没找到同一首歌的其他版本\n到搜索页换个关键词，或在「音源」页启用别的音源',
                    );
                  }
                  return ListView.builder(
                    itemCount: found.length,
                    itemBuilder: (_, i) => _row(ctx, found[i]),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext ctx, Song v) {
    final label = sourceLabel(v.source);
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      leading: _MiniCover(song: v),
      title: Text(v.name.isEmpty ? '未知歌曲' : v.name,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        [
          v.singer.isEmpty ? '未知歌手' : v.singer,
          label,
          if ((v.interval ?? 0) > 0) formatPlayTime(v.interval),
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: v.needsVip ? const VipBadge() : null,
      onTap: () => Navigator.pop(ctx, v),
    );
  }
}

class _MiniCover extends StatelessWidget {
  final Song song;
  const _MiniCover({required this.song});

  @override
  Widget build(BuildContext context) {
    const size = 38.0;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final pic = artUrl(song.pic, px: px);
    if (pic == null) {
      return SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.music_note, size: 18, color: AppTheme.textSecondary));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: CachedNetworkImage(
        imageUrl: pic,
        httpHeaders: artHeaders,
        width: size,
        height: size,
        memCacheWidth: px,
        memCacheHeight: px,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) =>
            const SizedBox(width: size, height: size, child: Icon(Icons.music_note, size: 18)),
      ),
    );
  }
}

/// 收藏 / 取消收藏一个歌单，并留一次撤销。详情页右上角、发现页长按、搜索结果长按
/// 走的是同一段：点了没别的可见反馈的话，她分不清是没生效还是没点上。
void toggleSheetFavorite(BuildContext context, SheetInfo sheet) {
  final added = LibraryStore.instance.toggleSheet(sheet);
  toast(
    context,
    added ? '已收藏歌单「${sheet.name}」' : '已取消收藏「${sheet.name}」',
    actionLabel: '撤销',
    onAction: () => LibraryStore.instance.toggleSheet(sheet),
  );
}

/// 加入歌单 picker: tick the playlists this song should live in, or make a new
/// one right here.
Future<void> pickPlaylist(BuildContext context, Song song) => showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.pageBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PlaylistPicker(song: song),
    );

class _PlaylistPicker extends StatelessWidget {
  final Song song;
  const _PlaylistPicker({required this.song});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final mine = store.playlistsOf(song);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('加入歌单',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Icon(Icons.playlist_add, size: 20, color: AppTheme.textSecondary),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
          ),
          Divider(height: 1, color: AppTheme.divider),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in store.playlists)
                  CheckboxListTile(
                    value: mine.any((e) => e.id == p.id),
                    activeColor: AppTheme.primary,
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -1),
                    controlAffinity: ListTileControlAffinity.trailing,
                    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
                    subtitle: Text('${p.songs.length} 首',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    onChanged: (on) {
                      if (on == true) {
                        store.addToPlaylist(p.id, song);
                      } else {
                        store.removeFromPlaylist(p.id, song);
                      }
                    },
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add_circle_outline, size: 22),
                  title: const Text('新建歌单'),
                  onTap: () => _create(context),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final store = LibraryStore.instance;
    final name = await promptText(
      context,
      title: '新建歌单',
      hint: '歌单名称',
      initial: '',
    );
    if (name == null || name.trim().isEmpty) return;
    final created = store.createPlaylist(name);
    store.addToPlaylist(created.id, song);
  }
}

/// Small labelled text dialog, used by 新建/重命名歌单.
Future<String?> promptText(BuildContext context,
    {required String title, required String hint, String initial = '', String confirmLabel = '确定'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: 24,
        decoration: InputDecoration(hintText: hint, counterText: ''),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(confirmLabel)),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

/// 不可逆动作（删本地文件、批量清空）前的一次确认。
Future<bool> confirmAction(BuildContext context,
    {required String title, required String message, String confirmLabel = '删除'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok == true;
}

/// Download entry point shared by every list and the player page.
Future<void> requestDownload(BuildContext context, Song song) async {
  final settings = AppSettings.instance;
  final dm = context.read<DownloadManager>();
  if (settings.confirmBeforeDownload) {
    // 落到磁盘的是哪一档，看的是这条音频从哪个平台来：会员歌换 B 站兜底的，
    // 设成无损也只有 192k。弹窗许一个拿不到的档位，下完她才发现不对就太晚了。
    final from = LibraryStore.instance.swapSongFor(song)?.source ?? song.source;
    final tier = heardQuality(settings.quality, from);
    final ok = await confirmAction(
      context,
      title: '开始下载',
      message: '将以 $tier 下载「${song.name}」。\n'
          '${tier == 'flac' ? '无损格式一首可达 30 MB 以上，' : ''}移动网络下会消耗流量。',
      confirmLabel: '下载',
    );
    if (!ok) return;
  }
  final started = await dm.enqueue(song);
  if (!context.mounted) return;
  // 已经在下的那一首不会重新排队，这时候说「已开始下载」就是骗人。
  toast(context, started ? '已开始下载，进度在「我的」页可见' : '这首已经在下载中了');
}

/// 一句话提示。收藏/排队这类操作点了没有别的可见变化，不吭一声她分不清
/// 是没生效还是没点上。可选一个「撤销」动作。
///
/// 报错条常驻很碍眼，所以默认 2 秒自己走：提示条盖在列表上，多留一秒就多挡一秒。
/// 但带按钮的那条得给够时间——「换版本」「重试」是要她读完再决定点不点的，
/// 2 秒连句子都没读完就没了，等于这条提示从来没打算让她点。
void toast(BuildContext context, String text, {String? actionLabel, VoidCallback? onAction}) {
  if (!context.mounted) return;
  final hasAction = actionLabel != null && onAction != null;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(text),
      duration: Duration(seconds: hasAction ? 4 : 2),
      behavior: SnackBarBehavior.floating,
      // 播放条现在是真正的 bottomNavigationBar，Scaffold 会把提示抬到它上面，
      // 这里只留 12 的呼吸距离；再留 84 就会浮到列表中间。
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      action: hasAction ? SnackBarAction(label: actionLabel, onPressed: onAction) : null,
    ));
}

/// 三行摘要，点一下展开全文（歌单 / 专辑简介用）。
class ExpandableDesc extends StatefulWidget {
  final String text;
  final EdgeInsets padding;
  const ExpandableDesc({super.key, required this.text, this.padding = EdgeInsets.zero});

  @override
  State<ExpandableDesc> createState() => _ExpandableDescState();
}

class _ExpandableDescState extends State<ExpandableDesc> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: GestureDetector(
        onTap: () => setState(() => _open = !_open),
        child: Text(
          _open ? '${widget.text}\n（收起）' : widget.text,
          maxLines: _open ? null : 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
        ),
      ),
    );
  }
}
