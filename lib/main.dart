import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'download/download_manager.dart';
import 'library/library_store.dart';
import 'ui/pages/builtin_library.dart';
import 'player/player_service.dart';
import 'settings/app_settings.dart';
import 'source/source_manager.dart';
import 'util/app_log.dart';
import 'util/humanize.dart';
import 'ui/pages/discover_page.dart';
import 'ui/pages/home_page.dart';
import 'ui/pages/library_page.dart';
import 'ui/player/player_bar.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  // 三个存储互不相干，并行读，冷启动少等两次磁盘。
  await Future.wait([
    AppSettings.instance.init(),
    SourceManager.instance.init(),
    LibraryStore.instance.init(),
    AppLog.init(),
  ]);
  AppLog.add('起', '听歌小窝 v${AppSettings.appVersion} 启动');
  // 崩溃和「歌自己停了」是她最没法转述的一种现象：留下最后一根线索，比事后追问
  // 「当时屏幕上写了什么」有用得多。只记类型和头一句，栈太长会把日志页挤满。
  FlutterError.onError = (details) {
    AppLog.add('崩', details.exceptionAsString());
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (e, s) {
    AppLog.add('崩', '$e');
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
          onAction: canSwap ? () => showOtherVersionsSheet(context, failed) : player.retry);
      return;
    }
    if (player.noticeTick != _seenNoticeTick) {
      _seenNoticeTick = player.noticeTick;
      if (!mounted) return;
      toast(context, player.notice ?? '');
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
