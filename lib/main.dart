import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:songbox_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'download/download_manager.dart';
import 'library/library_store.dart';
import 'ui/pages/builtin_library.dart';
import 'ui/pages/log_page.dart';
import 'player/player_service.dart';
import 'settings/app_settings.dart';
import 'source/source_manager.dart';
import 'util/app_log.dart';
import 'util/boot_failures.dart';
import 'util/humanize.dart';
import 'util/power_status.dart';
import 'ui/pages/discover_page.dart';
import 'ui/pages/home_page.dart';
import 'ui/pages/library_page.dart';
import 'ui/player/player_bar.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // 桌面版的声音：just_audio 官方只写了安卓和 Apple 两条后端，Windows 上每一次播放
    // 调用都是 MissingPluginException（界面照样起得来，就是永远放不出）。media_kit 那套
    // libmpv 顶上这一格。它默认只接 Windows/Linux，所以安卓那条路连这行都走不到。
    // title 是音量混合器里那一格显示的名字，留着默认的插件名太难认。
    JustAudioMediaKit.title = '听歌小窝';
    JustAudioMediaKit.ensureInitialized();
  } else {
    // Must run before any AudioPlayer is created: it replaces just_audio's
    // platform implementation with one that drives the media notification.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.wyj.music.lyric_music.playback',
      androidNotificationChannelName: '播放控制',
      androidNotificationChannelDescription: '听歌小窝后台播放与锁屏控制',
      androidNotificationOngoing: true,
      // 暂停时不退前台服务：MIUI / ColorOS 会优先杀没有前台通知的进程，
      // 暂停接个电话回来歌单就没了。通知常驻的代价小得多。
      androidStopForegroundOnPause: false,
      // 封面按原图（常常 1000px 以上）取回来说通知栏用，既慢又占内存。
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    );
  }
  // 三个存储互不相干，并行读，冷启动少等两次磁盘。
  // 每一块自己接住自己的失败：以前这里一个抛异常整批没人接，界面直接停在
  // 白屏上，而她看到的「收藏是空的」背后其实根本没走到记日志那一步。
  await Future.wait([
    _boot('设置', () => AppSettings.instance.init()),
    _boot('音源', () => SourceManager.instance.init()),
    _boot('曲库', () => LibraryStore.instance.init()),
    _boot('日志', () => AppLog.init()),
  ]);
  AppLog.add('起', '听歌小窝 v${AppSettings.appVersion} 启动');
  // 崩溃和「歌自己停了」是她最没法转述的一种现象：留下最后一根线索，比事后追问
  // 「当时屏幕上写了什么」有用得多。只记类型、头一句再加我们自己那几帧，整罐栈会把日志页挤满。
  FlutterError.onError = (details) {
    _logCrash(details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (e, s) {
    _logCrash('$e', s);
    return false;
  };
  PlayerService.instance
    ..bindResolvers(
      url: BuiltinLibrary.instance.cachedUrl,
      lyric: BuiltinLibrary.instance.cachedLyric,
      staleUrl: BuiltinLibrary.instance.forgetUrl,
      scanVip: BuiltinLibrary.instance.scanVipSongs,
    )
    ..start();
  // 音源脚本要在 QuickJS 里跑完初始化，最长等 20s。放后台激活，首屏不该停在
  // 白屏上——网易云直连的曲子不依赖它，先让用户进得去。
  final activeId = SourceManager.instance.activeSourceId;
  if (activeId != null) {
    // 交给 SourceManager 存着：后台自动换脚本要先等这次激活读完文件。
    SourceManager.instance.activation = () async {
      try {
        await SourceManager.instance.activate(activeId);
      } catch (e) {
        AppLog.add('源', '音源脚本激活失败，端内直连照常可用：${humanizeError(e)}');
      }
    }();
  }
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings.instance),
        ChangeNotifierProvider(create: (_) => LibraryStore.instance),
        ChangeNotifierProvider(create: (_) => DownloadManager.instance),
        ChangeNotifierProvider(create: (_) => PlayerService.instance),
        Provider(create: (_) => SourceManager.instance),
      ],
      child: const LyricApp(),
    ),
  );
}

/// 冷启动里某一块存储没起来：记进日志、攒进 [BootFailures]，让主壳在第一帧后说一声。
///
/// 「曲库没读出来」这种话不能只留在日志里——她那边的现象是收藏空了，
/// 而空列表看起来跟「还没收藏过」一模一样，谁也不会想到是读坏了。
Future<void> _boot(String what, Future<void> Function() run) async {
  try {
    await run();
  } catch (e) {
    BootFailures.add('$what没读出来（这一块的记录这次是空的）');
    AppLog.add('起', '$what初始化失败：$e');
  }
}

/// 崩的那一句后面跟我们自己的那几帧。只写「Unsupported operation: Cannot remove from an
/// unmodifiable list」时，屏幕上那句没告诉她是谁踩的，日志里也翻不出是哪个文件没落盘 ——
/// 而她能转述的只有这一句。
void _logCrash(String what, StackTrace? st) {
  final frames = AppLog.ownFrames(st);
  AppLog.add('崩', frames.isEmpty ? what : '$what · $frames');
}

class LyricApp extends StatefulWidget {
  const LyricApp({super.key});

  @override
  State<LyricApp> createState() => _LyricAppState();
}

class _LyricAppState extends State<LyricApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 收藏/最近播放是 2 秒防抖落盘的，退后台或被系统挂起时先冲一次，
  /// 不然「加完收藏直接切走」最容易丢的就是最后那一条。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      LibraryStore.instance.flushNow();
      SourceManager.instance.flushNow();
    }
    // 从下拉菜单/最近任务回到应用时补看一次播放卡：被系统抹掉的那一种不会自己回来，
    // 这里发现就顺手重贴，不用她去设置页找按钮。
    if (state == AppLifecycleState.resumed) PlayerService.instance.recheckMediaCard();
  }

  /// 选「跟随系统」时，系统深浅色翻了要重算一次色板。
  @override
  void didChangePlatformBrightness() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final dark = switch (settings.theme) {
      'dark' => true,
      'light' => false,
      _ => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
    };
    AppTheme.dark = dark;
    return MaterialApp(
      title: '听歌小窝',
      theme: AppTheme.palette(),
      // 换主题时整棵重建：页面的颜色是静态取的，不重建就会留着上一套色。
      home: MainShell(key: ValueKey('shell-$dark')),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  int _seenErrorTick = 0;
  int _seenNoticeTick = 0;
  int _seenCardTick = 0;
  /// 后台自检那一班：开屏 8 秒后跑第一次，之后每半天一次，由 [_runStartupChecks] 自己续排。
  Timer? _startupTimer;
  static const _checksInterval = Duration(hours: 12);

  // 三个 tab 各自一个 key：再点当前那个要能把「回到顶部」递到页面里。
  final _homeKey = GlobalKey();
  final _discoverKey = GlobalKey();
  final _libraryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    PlayerService.instance.addListener(_onPlayerChanged);
    // 开屏那几秒是首屏取链和音源初始化在抢网络，体检和脚本更新排在它们后面跑。
    _startupTimer = Timer(const Duration(seconds: 8), _runStartupChecks);
    // 冷启动哪块存储没读出来，第一帧之后一次性说一声。空列表和「读坏了」在界面上
    // 长得一模一样，不吭声她只会以为这版把收藏弄丢了。
    if (BootFailures.hasAny) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showBootFailures());
    }
  }

  void _showBootFailures() {
    if (!mounted) return;
    final all = BootFailures.drain();
    if (all.isEmpty) return;
    toast(context, all.length == 1 ? all.single : '这几样本机数据没读出来：${all.join('、')}',
        actionLabel: '看日志',
        onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogPage())));
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    PlayerService.instance.removeListener(_onPlayerChanged);
    super.dispose();
  }

  /// 半天一次的内置音源自动换新。后台活，不开口。
  Future<void> _runStartupChecks() async {
    // 这个进程可以活很多天（后台播放让系统不回收它），只跑开屏那一次的话，
    // 「半天一次」实际上变成「每次冷启动一次」。所以进来就先把下一班排上，
    // 后面的早退不会漏掉重排。
    _startupTimer = Timer(_checksInterval, _runStartupChecks);
    unawaited(SourceManager.instance.autoRefreshIfStale());
  }

  /// Playback failures surface here instead of at each of the call sites that
  /// can start playback.
  void _onPlayerChanged() {
    final player = PlayerService.instance;
    if (player.errorTick != _seenErrorTick) {
      _seenErrorTick = player.errorTick;
      if (!mounted) return;
      final failed = player.failedSong;
      // 会员墙这类错「重试」是白试，直接把「找其他版本」放到手边；
      // 放不出的那首已经被自动跳过去了，所以要认 failedSong 而不是当前这首。
      final canSwap = failed != null && looksLikeVipWall(player.error);
      toast(context, player.error ?? '播放失败',
          actionLabel: canSwap ? '换版本' : '重试',
          // 重试走 retryFailed：放不出之后已经自动跳了下一首，这颗键要跳回那首放不出的，
          // 按原来的 retry 听到的是另一首歌。
          onAction: canSwap ? () => showOtherVersionsSheet(context, failed) : player.retryFailed);
      return;
    }
    if (player.noticeTick != _seenNoticeTick) {
      _seenNoticeTick = player.noticeTick;
      if (!mounted) return;
      // 「中途停了」这一句后面得跟着一只手：接桥只管下拉那张卡，接不回声音，
      // 让她干等就是什么也没发生。别的情况照旧只是报一句。
      final stalled = player.idleStopped && player.current != null;
      // 定时到点停了，但「再听半小时」这种时候很常见：这一条直接给一次续，
      // 不用她再进「更多」里翻那一排分钟数。
      final rearm = player.sleepJustEnded;
      toast(context, player.notice ?? '',
          actionLabel: stalled ? '接着放' : (rearm ? '再定 ${player.lastSleep.inMinutes} 分钟' : null),
          onAction: stalled
              ? player.retry
              : (rearm ? player.rearmSleepTimer : null));
    }
    // 下拉菜单里那张播放卡没到系统里 —— 病因不同，去处也不同，动作直接放在提示条上，
    // 不让她自己去设置页里找。
    if (player.cardTick != _seenCardTick) {
      _seenCardTick = player.cardTick;
      if (!mounted) return;
      final problem = player.cardProblem;
      final (String msg, String label) = switch (problem) {
        MediaCardVerdict.notificationsOff => ('系统把听歌小窝的通知关了，下拉菜单里看不到播放卡', '去开启'),
        MediaCardVerdict.channelBlocked => ('「播放控制」那一栏的通知被关掉了，播放卡出不来', '去开启'),
        MediaCardVerdict.notificationsPaused => ('手机开着「暂停通知」，播放卡这段时间上不了屏', '去关掉'),
        MediaCardVerdict.hiddenByRom => (
            '播放卡已经发出去了，是手机不让它上屏，去通知设置里放行',
            '去开启',
          ),
        MediaCardVerdict.postedElsewhere => ('播放卡挂在另一栏上，点一下把它挪回「播放控制」', '重发一次'),
        _ => ('歌在放，但播放卡没送到系统里，点一下重发', '重发一次'),
      };
      toast(context, msg, actionLabel: label, onAction: () => _fixCard(problem));
    }
  }

  Future<void> _fixCard(MediaCardVerdict problem) async {
    switch (problem) {
      case MediaCardVerdict.notificationsOff:
      case MediaCardVerdict.notificationsPaused:
      case MediaCardVerdict.hiddenByRom:
        await PowerStatus.openNotificationSettings();
      case MediaCardVerdict.channelBlocked:
        await PowerStatus.openChannelSettings();
      default:
        await PlayerService.instance.repostCard();
    }
  }

  /// 再点当前 tab：把「回到顶部」递进页面里。三个 key 的顺序和 tab 一致。
  void _scrollCurrentTabToTop() {
    final key = [_homeKey, _discoverKey, _libraryKey][_tab];
    (key.currentState as ScrollToTop?)?.scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(key: _homeKey, onOpenTab: (i) => setState(() => _tab = i)),
      DiscoverPage(key: _discoverKey),
      LibraryPage(key: _libraryKey),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      // 播放条放在标签栏同一条 bottomNavigationBar 里，而不是浮层：Scaffold 会把
      // 页面内容整体往上抬，列表最后一行不会被条盖住（网易云也是这样）。
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PlayerBar(reserveNavInset: false),
          BottomNavigationBar(
            currentIndex: _tab,
            // 已经在这个 tab 上再点一次：回到顶部，网易云也是这样。
            onTap: (i) => i == _tab ? _scrollCurrentTabToTop() : setState(() => _tab = i),
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: '首页'),
              BottomNavigationBarItem(icon: Icon(Icons.explore_outlined), activeIcon: Icon(Icons.explore), label: '发现'),
              BottomNavigationBarItem(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: '我的'),
            ],
          ),
        ],
      ),
    );
  }
}
