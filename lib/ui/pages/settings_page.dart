import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../download/download_manager.dart';
import '../../library/library_store.dart';
import '../../models/song.dart';
import '../../player/audio_prefetch.dart';
import '../../player/player_service.dart';
import '../../settings/app_settings.dart';
import '../../util/power_status.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'diagnostic_page.dart';
import 'log_page.dart';

/// 播放设置 — quality preference, cache clearing, search history, version.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _clearCache(BuildContext context) async {
    final dm = context.read<DownloadManager>();
    // 先量、再问、最后才删。原来第一步就是 deleteImageCache()：缓存早在她看到
    // 那句「只清缓存 / 全部删除」之前就没掉了，那个选择从来不算数。
    final bytes =
        await DownloadManager.imageCacheBytes() + await AudioPrefetch.instance.pendingBytes();
    final musicBytes = await DownloadManager.musicDirBytes();
    if (!context.mounted) return;
    final doMusic = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('清除缓存'),
        content: Text('图片与预取歌曲缓存 ${_fmt(bytes)}\n已下载音乐 ${_fmt(musicBytes)}\n\n'
            '${musicBytes == 0 ? '暂时还没有下载文件。' : '是否连同已下载的音乐一起删除？'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('先不清')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('只清缓存')),
          if (musicBytes > 0)
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('全部删除')),
        ],
      ),
    );
    // 「先不清」和按返回键都算她反悔：这一次一个文件都不动。
    if (doMusic == null) return;
    // 预取下来还没播到的歌也算缓存，一起清掉。
    final freedCache =
        await DownloadManager.deleteImageCache() + await AudioPrefetch.instance.clearAll();
    if (doMusic == false) {
      if (!context.mounted) return;
      toast(context, '已清出 ${_fmt(freedCache)}（歌曲收藏与音源设置保留）');
      return;
    }
    // 删完再报数：以「删之前量到的占用」当「清出来的体积」，遇到一首删不掉就是纯骗人。
    final freedMusic = await dm.deleteAllDownloads();
    if (!context.mounted) return;
    toast(context, '已清出 ${_fmt(freedCache + freedMusic)}');
  }

  static String _fmt(int bytes) {
    if (bytes <= 0) return '0 KB';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    // 无损攒到几个 G 是常事，写成「2560.0 MB」不如 2.5 GB 一眼读得出来。
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('播放设置')),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text('播放音质', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          RadioGroup<String>(
            groupValue: settings.quality,
            onChanged: (v) {
              if (v == null) return;
              settings.setQuality(v);
              final playing = PlayerService.instance.current;
              if (playing != null && !LibraryStore.instance.hasLocalFile(playing)) {
                toast(context, '下一首起使用新音质，当前这首继续播放');
              }
            },
            child: Column(
              children: [
                for (final q in AppSettings.qualities)
                  RadioListTile<String>(
                    value: q,
                    title: Text(qualityLabel(q)),
                    subtitle: Text(_qualityHint(q),
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    activeColor: AppTheme.primary,
                  ),
              ],
            ),
          ),
          Divider(height: 24, color: AppTheme.divider),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('外观', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final t in AppSettings.themeValues)
                  _ThemeChip(
                    label: switch (t) {
                      'light' => '浅色',
                      'dark' => '深色',
                      _ => '跟随系统',
                    },
                    selected: settings.theme == t,
                    onTap: () => settings.setTheme(t),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('深色在夜里听歌不刺眼；跟随系统会跟着手机切换。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Divider(height: 24, color: AppTheme.divider),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text('播放行为', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            value: settings.autoSkipFailed,
            onChanged: settings.setAutoSkipFailed,
            activeThumbColor: AppTheme.primary,
            title: const Text('自动跳过放不出的歌'),
            subtitle: Text('遇到会员专享或链接失效的曲子时继续往下放，不在这里停住',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.vipAutoScan,
            onChanged: settings.setVipAutoScan,
            activeThumbColor: AppTheme.primary,
            title: const Text('会员歌自动找免费版'),
            subtitle: Text('换队列时在后台一次性把整单的会员歌换成能播的同一版本，结果会存下来复用',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.preloadNext,
            onChanged: settings.setPreloadNext,
            activeThumbColor: AppTheme.primary,
            title: const Text('提前备好下一首'),
            subtitle: Text('快播完时把下一首先取回手机，切歌立刻出声、不留空白；'
                '代价是多用一首歌的流量，省流量时可以关掉',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.confirmBeforeDownload,
            onChanged: settings.setConfirmBeforeDownload,
            activeThumbColor: AppTheme.primary,
            title: const Text('下载前先问一句'),
            subtitle: Text('用移动网络时不容易察觉，无损一首几十兆',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          const _BackgroundRow(),
          const _NotificationRow(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('小米、OPPO 还要在「最近任务」里把听歌小窝往下拉锁定，'
                '否则一键清理会连着把后台网络一起断掉。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('音源自检'),
            subtitle: Text('逐个问一遍网易云、QQ、音源脚本、B 站、酷狗，看这个网络上能不能拿到整首；'
                '同一首歌换个网络结果可能不一样，跑一次十几秒',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DiagnosticPage()),
            ),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('听歌日志'),
            subtitle: Text('每次开播、换源、断流、重试都留了一行。哪首歌放不出时把它复制发我，'
                '不用描述现象；只记歌名和结果，不记账号信息',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogPage()),
            ),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('搜索历史'),
            subtitle: Text(settings.searchHistory.isEmpty ? '暂无记录' : '共 ${settings.searchHistory.length} 条',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            trailing: settings.searchHistory.isEmpty
                ? null
                : TextButton(
                    onPressed: () {
                      // 抄一份再清：searchHistory 是设置里那份活的列表，直接传过去会被清成空的。
                      final snap = List<String>.from(settings.searchHistory);
                      settings.clearSearchHistory();
                      toast(context, '已清空搜索历史',
                          actionLabel: '撤销', onAction: () => settings.restoreSearchHistory(snap));
                    },
                    child: const Text('清空'),
                  ),
          ),
          ListTile(
            title: const Text('清除缓存'),
            subtitle: Text('封面与预取的歌曲缓存、已下载音乐',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            onTap: () => _clearCache(context),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('关于'),
            subtitle: Text('听歌小窝 v${AppSettings.appVersion}\n'
                '网易云、QQ 的歌在端内直连播放，全程匿名，不需要登录任何账号；'
                '会员专享的会自动换成 B 站、酷狗同一首的整首；'
                '「音源管理」只是多接几个曲库的入口，不启用也能听。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _qualityHint(String q) => switch (q) {
        '128k' => '最省流量，任何曲库都能放',
        'flac' => '音质最好，只有部分歌曲提供，加载更慢',
        _ => '默认推荐，流量下也比较合适',
      };
}

/// 息屏之后系统会不会掐掉后台网络，只有原生侧知道。这一行把状态摊开，并且直接
/// 把她带到能放行的那一页；从授权框或厂商设置页回来时重新问一次，改完立刻看得见。
class _BackgroundRow extends StatefulWidget {
  const _BackgroundRow();

  @override
  State<_BackgroundRow> createState() => _BackgroundRowState();
}

class _BackgroundRowState extends State<_BackgroundRow> with WidgetsBindingObserver {
  bool? _ignoring;
  bool _powerSave = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final ignoring = await PowerStatus.ignoringBatteryOptimizations();
    final save = await PowerStatus.powerSaveMode();
    if (!mounted) return;
    setState(() {
      _ignoring = ignoring;
      _powerSave = save;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ignoring = _ignoring;
    final ok = ignoring == true;
    return ListTile(
      title: const Text('息屏后台播放'),
      subtitle: Text(
        ignoring == null
            ? '正在确认系统的后台限制…'
            : ok
                ? (_powerSave
                    ? '已允许后台运行；不过手机现在在省电模式，仍可能限制网络'
                    : '已允许后台运行，息屏也能连着网继续放')
                : '系统还在限制后台网络，息屏后容易连不上、歌就停了',
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: ignoring == null
          ? null
          : ok
              ? Icon(Icons.verified_outlined, color: AppTheme.primary)
              : TextButton(
                  onPressed: () => PowerStatus.askIgnoreBatteryOptimizations(),
                  child: const Text('去放行'),
                ),
      onTap: ok || ignoring == null ? null : () => PowerStatus.askIgnoreBatteryOptimizations(),
    );
  }
}

/// 通知栏那张控制卡就是一条媒体通知，控制中心里「在放什么」那一格读的是同一样东西：
/// 通知被系统关掉、被单独静默、或者压根没贴上去，那一格就只剩「暂无播放」，
/// 而她在手机上看不出是哪一种。这里把系统给的证据摊成一句人话加一行取证，右边就是能点的动作。
class _NotificationRow extends StatefulWidget {
  const _NotificationRow();

  @override
  State<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<_NotificationRow> with WidgetsBindingObserver {
  MediaCardState _state = const MediaCardState();
  bool _playing = false;
  bool _busy = false;
  StreamSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // 卡片是开始放的那一刻才贴上去的，所以只在「开始放」之后重查一次。
    _playingSub = PlayerService.instance.playingStream.listen((p) {
      if (p) _load();
    });
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    // 走播放层：它除了原生那半截，还知道桥里最后一次说了什么、桥报过几次错。
    final st = await PlayerService.instance.cardEvidence();
    if (!mounted) return;
    setState(() {
      _state = st;
      _playing = PlayerService.instance.isPlaying;
    });
  }

  /// 暂停再播放会逼播放服务把这张卡重新贴一遍，也是让手机重新认一次这个会话。
  Future<void> _repost() async {
    if (_busy || !PlayerService.instance.isPlaying) return;
    setState(() => _busy = true);
    await PlayerService.instance.repostCard();
    // 卡片是状态变化之后才贴上去的，立刻查只会查到旧局面。
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;
    setState(() => _busy = false);
    _load();
  }

  /// 手动逼一次接桥。自动那一趟只在原生不肯交出那个对象时才轮得到她动手。
  Future<void> _heal() async {
    if (_busy) return;
    setState(() => _busy = true);
    await PlayerService.instance.healBridge();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;
    setState(() => _busy = false);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final verdict = _state.verdict(playing: _playing);
    // 卡显示得好好的、按钮却按不动，是这第三种病：原生那半截桥被上一次 idle 拆了。
    final bridgeDead = _state.listenerAlive == false;
    final (copy0, action) = switch (verdict) {
      MediaCardVerdict.notificationsOff => (
          '系统把听歌小窝的通知关着，下拉看不到播放卡，控制中心那一格也是空的',
          '去开启',
        ),
      MediaCardVerdict.channelBlocked => (
          '整罐通知是开的，单是「播放控制」这一栏被关掉了',
          '去开启',
        ),
      MediaCardVerdict.notificationsPaused => (
          '手机开着「暂停通知」，这段时间所有通知都不上屏，播放卡被一起按住',
          '去关掉',
        ),
      MediaCardVerdict.notPosted => ('歌在放，但播放卡没贴到系统里，重发一次一般就好', '重发一次'),
      MediaCardVerdict.postedElsewhere => (
          '播放卡在系统里，只是挂在另一栏上；重发一次能把它挪回「播放控制」',
          '重发一次',
        ),
      MediaCardVerdict.hiddenByRom => (
          '卡片已经发出去了，是手机不让它上屏。重发没用，去通知设置里放行',
          '去开启',
        ),
      MediaCardVerdict.inSystem => bridgeDead
          ? (
              '卡上的按钮按了没反应：上一次放到一半断了线，应用会自己接回来；'
                  '接不回来时点这一下逼它一次',
              '接回来',
            )
          : (
              // 0.8.31 起卡上那两个箭头接的是应用自己的切歌，不再是「画出来给人看」，
              // 这一行也就只管告诉她卡在了系统里、以及那一格还空时该怎么办。
              '播放卡已经在系统里：暂停、上一首、下一首在卡上都管用，切歌走的就是应用里'
                  '那同一套（逐首取链、放不出自动降音质换平台）。'
                  '那一格还是空的就重发一次；再不行是手机的媒体模块没接上，不影响听歌',
              '重发一次',
            ),
      MediaCardVerdict.idle => ('放一首歌再看这一行，就能确认系统那边收到没有', null),
      MediaCardVerdict.unknown => ('正在确认系统里的播放卡…', null),
    };
    // 通道一个都没有 = 服务这一趟压根没走到发通知那一步，和「贴上去了又被一键清理抹掉」
    // 不是同一种病：那一种重贴正好，这一种得先看服务为什么没走到。而「服务起过却没挂上
    // 通知」和「话压根没递到服务那边」又是两处不同的断点，取证那一行分得开。
    final noChannel = verdict == MediaCardVerdict.notPosted && _state.channelImportance == null;
    final why = switch (_state.serviceStarted) {
      true => '播放服务起来了，却没把这张卡挂上系统',
      false => '歌在放，但话没递到播放服务那一边',
      null => '歌在放，但播放服务这一趟还没走到发通知那一步',
    };
    // 桥断着的时候，暂停再播放走的还是同一座桥，所以那种局面不承诺「点一下就好」，
    // 只把原文指给她看 —— 异常名字里就写着断在哪一跳。
    final err = _state.bridgeErrors > 0
        ? '，和播放服务说话错了 ${_state.bridgeErrors} 次（原文在下面那行末尾）'
        : '';
    final copy = noChannel
        ? (_state.bridgeErrors > 0 ? '$why$err' : '$why，点一下逼它重走一遍')
        : copy0;
    // 出毛病时把系统答的原始证据一并摊开：她截一张图，我这边就能定案，
    // 不用再猜一轮、再打一个包让她重装。
    final showDetail = bridgeDead ||
        (verdict != MediaCardVerdict.inSystem &&
            verdict != MediaCardVerdict.idle &&
            verdict != MediaCardVerdict.unknown);
    // 「重发一次」只对卡片没贴上去有效；被系统按住的那几种，发一万次也一样。
    final repost =
        verdict == MediaCardVerdict.notPosted || verdict == MediaCardVerdict.postedElsewhere;
    // 按钮上的字和它真正做的事得是同一样。卡没贴上去时先重发 —— 桥真断着，
    // 重发完那次复查（_checkMediaCard）自己会接，不用她再按第二下。
    Future<void> act() =>
        repost ? _repost() : (bridgeDead ? _heal() : _openSettings(verdict));
    return ListTile(
      title: const Text('下拉菜单里的播放卡'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(copy, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
          if (showDetail)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _state.detail,
                style: TextStyle(fontSize: 11, height: 1.4, color: AppTheme.textSecondary.withAlpha(150)),
              ),
            ),
        ],
      ),
      trailing: action == null
          ? null
          : _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(onPressed: act, child: Text(action)),
      onTap: action == null || _busy ? null : act,
    );
  }

  /// 关着的那几种要去的不是同一页：整罐开关在应用通知页，
  /// 单被静默的那一栏只有通道页能改。
  Future<void> _openSettings(MediaCardVerdict verdict) async {
    if (verdict == MediaCardVerdict.channelBlocked) {
      await PowerStatus.openChannelSettings();
    } else {
      await PowerStatus.openNotificationSettings();
    }
  }
}

/// 主题选择的小药丸。自己画而不用 ChoiceChip：选中态的颜色要跟/// AppTheme 走，Material 的 chip 在深色底上分不清哪一个是当前项。
class _ThemeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.pillBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? AppTheme.primary : AppTheme.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}
