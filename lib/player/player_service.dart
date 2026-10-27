import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' show AudioService;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart';
import 'package:songbox_audio_background/just_audio_background.dart' show JustAudioBackground, MediaItem;

import '../library/library_store.dart';
import '../models/results.dart';
import '../models/song.dart';
import '../music_sdk/bl_source.dart';
import '../settings/app_settings.dart';
import '../util/app_log.dart';
import '../util/art_url.dart';
import '../util/humanize.dart';
import '../util/power_status.dart';
import 'audio_prefetch.dart';

class LyricLine {
  final int timeMs;
  final String text;

  /// Second language line, when the source ships one (NetEase `transl`).
  String? translated;
  LyricLine(this.timeMs, this.text, {this.translated});
}

class LyricParser {
  static List<LyricLine> parse(String raw) {
    final lines = <LyricLine>[];
    final re = RegExp(r'\[(\d+):(\d+)(?:\.(\d+))?\](.*)');
    for (final line in const LineSplitter().convert(raw)) {
      final matches = re.allMatches(line).toList();
      if (matches.isEmpty) continue;
      // metadata like [ar:..] won't match numeric groups strongly; skip non-numeric
      for (final m in matches) {
        final min = int.tryParse(m.group(1) ?? '');
        final sec = int.tryParse(m.group(2) ?? '');
        if (min == null || sec == null) continue;
        final ms = (m.group(3) != null) ? int.tryParse(m.group(3)!.padRight(3, '0')) ?? 0 : 0;
        final time = min * 60000 + sec * 1000 + ms;
        final text = m.group(4)?.trim() ?? '';
        if (text.isNotEmpty) lines.add(LyricLine(time, text));
      }
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }

  /// Puts the translation under the line that shares its timestamp. The two
  /// tracks rarely have the same line count (the original carries 作词/作曲
  /// headers) and their stamps differ by tens of milliseconds, so pair by
  /// nearest time within a second and a half rather than by position.
  static List<LyricLine> merge(LyricResult p) {
    final lines = parse(p.lyric);
    final tlyric = p.tlyric;
    if (lines.isEmpty || tlyric == null || tlyric.trim().isEmpty) return lines;
    final trans = parse(tlyric);
    if (trans.isEmpty) return lines;
    var j = 0;
    for (final l in lines) {
      while (j < trans.length && trans[j].timeMs < l.timeMs - 1500) {
        j++;
      }
      if (j < trans.length && (trans[j].timeMs - l.timeMs).abs() <= 1500) {
        l.translated = trans[j].text;
      }
    }
    return lines;
  }
}

/// How the queue advances when a track reaches its end.
enum PlayMode { list, single, random, none }

/// Standard 5-band preset gains in dB (bass / low-mid / mid / high-mid / treble).
class EqPreset {
  final String name;
  final List<double> gains;

  /// 这一档听上去是什么：`+8 +5 0 -2 -1` 这种数字读不出「低音更沉」还是「人声更贴」，
  /// 而选音效靠的正是后面那半句。
  final String desc;
  const EqPreset(this.name, this.gains, {this.desc = ''});
}

const eqPresets = <EqPreset>[
  EqPreset('平坦', [0, 0, 0, 0, 0], desc: '不加不减，原样放出来'),
  EqPreset('重低音', [8, 5, 0, -2, -1], desc: '鼓点与贝斯更沉，人声往后让一点'),
  EqPreset('清晰人声', [-2, 0, 4, 3, 1], desc: '人声拉到前面，伴奏退一步'),
  EqPreset('流行', [3, 1, -1, 2, 4], desc: '两头抬一点，听感更亮'),
  EqPreset('摇滚', [5, 2, -1, 3, 4], desc: '低频厚实、高音更冲'),
  EqPreset('古典', [4, 2, 0, 2, 3], desc: '整体略抬，乐器分得开一点'),
  EqPreset('电子', [6, 3, -1, 2, 5], desc: '低音狠、高音亮'),
  EqPreset('柔和', [2, 1, 0, 1, 2], desc: '轻微润色，久听不累'),
  EqPreset('低音减弱', [-4, -2, 0, 1, 2], desc: '觉得轰头时选这个，人声更干净'),
];

typedef UrlResolver = Future<String> Function(Song song, String quality);

/// Tells the catalog layer that the URL it handed back for this song is not
/// playable, so its short cache must drop it before the next attempt.
typedef UrlStaler = void Function(Song song, String quality);

/// Main timed lyric plus its optional translation track, in the lx-music shape
/// the sources already speak (`lyric` / `tlyric`).
typedef LyricResolver = Future<LyricResult> Function(Song song);

/// 批量给会员歌找免费版本，返回「找到几首 / 确认没有几首 / 一共几首」。
/// [cancelled] 每批开始前问一次：她换了队列，剩下的那些马上要重新排，别再发请求。
typedef VipScanner = Future<({int fixed, int dead, int total})> Function(List<Song> songs,
    {bool Function()? cancelled});

/// Single source of truth for playback. Pages only call [playList] / [togglePlay]
/// / [next] and read state through provider — resolving a stream URL and its
/// lyric is this class' job, not the caller's.
class PlayerService extends ChangeNotifier with WidgetsBindingObserver {
  static final PlayerService instance = PlayerService._();
  PlayerService._();

  UrlResolver? _urlResolver;
  LyricResolver? _lyricResolver;
  UrlStaler? _urlStaler;
  VipScanner? _vipScanner;

  /// Injected once from main() so the player stays decoupled from the catalog
  /// layer (and the iOS/Android differences that come with it).
  void bindResolvers({
    required UrlResolver url,
    required LyricResolver lyric,
    UrlStaler? staleUrl,
    VipScanner? scanVip,
  }) {
    _urlResolver = url;
    _lyricResolver = lyric;
    _urlStaler = staleUrl;
    _vipScanner = scanVip;
  }

  /// 安卓的系统均衡器。桌面版上它不进音频管道，也就永远不会去碰那条不存在的通道。
  final AndroidEqualizer _eq = AndroidEqualizer();

  late final AudioPlayer _ap = AudioPlayer(
    // androidAudioEffects 会让 just_audio 去安卓那侧建一个伴生播放器挂效果器，桌面上
    // 那次调用没人接。给一条空管道，其余（音量、倍速、seek）照旧。
    audioPipeline: Platform.isAndroid ? AudioPipeline(androidAudioEffects: [_eq]) : AudioPipeline(),
  );

  final List<Song> queue = [];
  int index = -1;
  List<LyricLine> lyric = [];
  int lyricIndex = -1;
  PlayMode playMode = PlayMode.list;
  String eqPresetName = '平坦';
  List<double> eqGains = const [0, 0, 0, 0, 0];

  /// 挂/摘效果器失败的那句话，给均衡器页直接看。
  String? eqError;
  bool _eqRestored = false;

  /// 倍速追剧/听歌常用，跨歌曲保持。
  static const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
  double _speed = 1.0;
  double get speed => _speed;

  /// True while a track is being resolved or loaded.
  bool busy = false;

  /// 歌词另给一个标志：音频先开播，取词还排在后面，复用 [busy] 会闪一句「暂无歌词」。
  bool lyricBusy = false;

  /// Human-readable reason the last playback attempt failed, or null.
  String? error;

  /// Bumped with every new [error] so listeners can show each failure once.
  int errorTick = 0;

  /// 最近一次放不出来的那首。自动跳下一首之后 [current] 已经不是它了，
  /// 而「找其他版本」必须知道到底是哪首要换。
  Song? failedSong;

  /// A non-failure message worth telling the user about (定时关闭, 全部跳过 …).
  String? notice;
  int noticeTick = 0;

  /// 正在等重连时给界面的一句话；没在等就是 null。
  ///
  /// 和 [notice] 的分别在那一条会自己消失：提示条两秒收走，而等重连是 5 秒、15 秒、
  /// 30 秒地等。屏幕上一点动静都没有的话，她的感受是「歌停了也不知道它在不在干活」，
  /// 只能自己反复点播放。这一句挂在播放条上，等回来自己就没了。
  String? get waitNote {
    if (_netRetry == null) return null;
    return _netRetries <= 1 ? '在等网络回来，会自动接着放' : '第 $_netRetries 次等网络回来';
  }

  /// 下拉菜单那张播放卡没到系统里时，这里递一次信：主壳看见新 tick 就把
  /// 「去开启 / 重发一次」放到她手边的提示条上，而不是让她去设置页里找。
  int cardTick = 0;
  MediaCardVerdict cardProblem = MediaCardVerdict.idle;

  /// 发现「系统里没卡」时先自己重贴一次，修好了就不吵她；一个毛病只自动修一次，
  /// 免得和重贴后那次复查来回打转。
  bool _cardRepaired = false;

  /// 应用和播放服务之间那座桥出错时既不响也不崩：audio_service 把异常全吞进
  /// [AudioService.asyncError]，而这条流没人接就什么都留不下。「歌在放、卡永远
  /// 不出现」最难查的正是这一种，所以必须接住、记账、写进日志。
  int _bridgeErrors = 0;

  /// 头一次报错的原文（截短）。异常名字本身就指向断在哪一跳，印在取证行上，
  /// 一张截图就够定案，不用她再去翻日志页。
  String? _firstBridgeError;
  StreamSubscription<Object>? _bridgeSub;

  Timer? _cardTimer;

  /// 桥被 idle 拆掉之后自己接回来的那一趟延时。
  Timer? _bridgeHeal;

  /// 上一次因为接桥而重贴卡的时刻。重贴会掐掉正在放的那一首半秒，两趟之间得留间隔。
  DateTime _lastBridgeRepost = DateTime(2000);

  Timer? _sleepTimer;
  Timer? _sleepTick;
  DateTime? _sleepEndsAt;

  /// How many consecutive tracks failed to resolve since the last success — the
  /// guard that keeps auto-skip from spinning through the queue forever.
  int _failStreak = 0;

  /// 最近一次失败是不是撞在会员墙上。整条队列跳完时要说的结论得对得上原因：
  /// 一片会员歌让人去「检查网络」是白跑一趟。
  bool _lastFailVip = false;

  /// 已经为「连不上」这一类失败等过几轮了。息屏被省电策略掐网的时候，整条取链子
  /// 都会报连不上，此时往下跳只是把剩下的歌一路标成放不出；停在当前这首等网络回来
  /// 才对得上「它在放歌」的直觉。间隔逐次拉长，四轮还不行才认输走原来的跳过逻辑。
  static const _netRetryDelays = [5, 15, 30, 60];
  int _netRetries = 0;
  Timer? _netRetry;

  /// 断流那一刻听到的位置。重试统一走 [playAt]，而它每次都要重下音源、从 00:00
  /// 起播 —— 已经听到 2:13 的歌在网络回来之后从头放，听感上就是这首歌被弄丢了。
  /// 记下时带上是哪一首：只有键对得上才用掉它，任何分支都不留残留，
  /// 免得下次切到别的歌接到旧位置上去。
  Duration? _resumeAt;
  String? _resumeKey;

  /// 前几秒就断的多半是取链或文件本身的问题，从头重试才对，接着放只会反复撞同一处。
  static const _resumeFloor = Duration(seconds: 5);

  /// 「地址没打开」那一回自动重取占掉的播放序号：重取走的是 [playAt]，序号必然 +1，
  /// 所以把 +1 记下来，正好用来认出「这次失败就是重取那一趟发出来的」。不记的话，
  /// 一首真放不出的歌会在错误回调和重取之间来回弹，永远停不下来。
  int _sourceRetryGen = -1;

  /// 断流时 [_ap] 的 position 有可能已经被清回零，所以边播边把最后听到的位置留着。
  Duration _lastHeard = Duration.zero;

  /// 自然播完的那首已经在 [_onTrackEnd] 记过账，紧跟着那一次 [playAt] 别再把它
  /// 记成「听到一半跳走」—— 一次播放只该记一次。
  String? _endNoted;

  /// 人已经不在应用里了（息屏、切走）。这时候系统随时可能掐掉后台网络，所以本地
  /// 备着的歌就是唯一的保险，多备一首值得。
  bool _background = false;

  /// 上一次播放器报上来的「在放吗」。只为认出后面那一下翻转是谁按的，见 [_playingSub]。
  bool _lastPlaying = false;

  /// 这一次的声音是从哪儿来的，只为写进日志：出问题时第一句要问的就是
  /// 「是本机文件还是现取的网络地址」。见 [_sourceFor]。
  String _how = '';

  /// 日志里的歌名：两边都截一下，一条 200 行的日志要能在手机屏幕上看完。
  static String _t(Song s) {
    final n = s.name.isEmpty ? '未知歌曲' : s.name;
    return n.length <= 18 ? n : '${n.substring(0, 18)}…';
  }

  static String _mm(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    // 回到前台是查桥最划算的一刻：卡上那几个键在后台按下去是静默无反应，Dart 这边
    // 一点动静都没有，只有她回到应用里我们才能问一句「桥还在吗」。
    // 桥好着的话 _healBridge 直接返回，不会掐她正在听的那一首。
    if (!_background && _ap.playing) {
      _scheduleBridgeHeal('回到应用', after: const Duration(milliseconds: 600));
    }
  }

  final Random _rnd = Random();
  int _generation = 0;

  /// 已经为队列里的第几首预取过了，防止每个位置 tick 都发一遍请求。
  int _prefetchFor = -1;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerException>? _errorSub;

  Stream<Duration> get positionStream => _ap.positionStream;
  Stream<Duration?> get durationStream => _ap.durationStream;
  Stream<PlayerState> get playerStateStream => _ap.playerStateStream;
  Stream<bool> get playingStream => _ap.playingStream;
  bool get isPlaying => _ap.playing;
  Duration get position => _ap.position;
  Duration? get duration => _ap.duration;

  Song? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get hasCurrent => current != null;

  /// Whether this row is the song on screen — lists highlight it and the ⋮ menu
  /// marks it, the same way 网易云 does.
  bool isCurrent(Song s) {
    final c = current;
    return c != null && c.source == s.source && c.songmid == s.songmid;
  }

  /// Wires auto-advance, lyric sync and playing-state republish. Idempotent.
  void start() {
    if (_stateSub != null) return;
    WidgetsBinding.instance.addObserver(this);
    // 卡上那两个箭头交给应用自己的切歌，不再走插件队列（一首一首装源时它永远
    // 没有 next/previous）。赋的正是播放条上那同一对方法，所以界面里的行为一个
    // 字节都没变；钩子一挂上，副本就把它进控件表，系统这才认为这两键可用。
    JustAudioBackground.onSkipToNext = _cardSkip(next, '下一首');
    JustAudioBackground.onSkipToPrevious = _cardSkip(previous, '上一首');
    // 预取目录里还留着上次下的整首，先扫进内存表：这趟磁盘往返不该排在第一次切歌前面。
    unawaited(AudioPrefetch.instance.prime());
    _speed = speeds.contains(AppSettings.instance.playbackSpeed) ? AppSettings.instance.playbackSpeed : 1.0;
    // 循环模式跟着人走，不跟着这一次队列走：存的名字对不上（手改过设置文件）就当列表循环。
    playMode =
        PlayMode.values.firstWhere((m) => m.name == AppSettings.instance.playMode, orElse: () => PlayMode.list);
    // 效果器随播放器实例一起没了，界面先按存下来的名字显示，第一首再接上真值。
    final savedEq = AppSettings.instance.eqPreset;
    eqPresetName = savedEq == '关闭' || eqPresets.any((p) => p.name == savedEq) ? savedEq : '关闭';
    _stateSub = _ap.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) _onTrackEnd();
      // idle 是会把播放卡按掉的那一下：原生收到 idle 就 stopSelf()，onDestroy 里把
      // 桥那半截的 listener 清空（AudioService.java:565 和 :363）。之后卡照样贴得出来
      // （发通知走的是静态 instance，用不着 listener），按钮却全落在空处，而且界面
      // 一点异常都收不到。放歌中途断流、地址坏掉都会报 idle，所以这里得自己接回去。
      if (s.processingState == ProcessingState.idle) {
        _scheduleBridgeHeal('放歌中途桥被拆了');
        _tellIfIdleStopped();
      }
    });
    _playingSub = _ap.playingStream.listen((p) {
      // 那张卡是进入播放态那一刻才贴上去的，所以每次开始放之后都去原生看一眼。
      if (p) {
        _scheduleCardCheck();
        // 清空队列之后卡上的 ▶ 还留着，按下去会把刚扔掉的那首又拽起来放。
        if (current == null && !busy) {
          unawaited(_ap.pause());
          AppLog.add('卡', '卡上按了播放，可队列早就空了，重新按住');
          notifyListeners();
          return;
        }
      }
      // 界面在身后时，playing 只可能是她从卡上那三个键（或线控）按出来的。留一行，
      // 下次她说「按钮不动」时能一眼看出那一下到底传到播放器没有。
      if (_background && p != _lastPlaying) {
        AppLog.add('卡', p ? '收到卡上的播放' : '收到卡上的暂停');
      }
      _lastPlaying = p;
      notifyListeners();
    });
    _positionSub = _ap.positionStream.listen((p) {
      if (_ap.playing) _lastHeard = p;
      _releaseSeekHold(p);
      if (_updateLyricIndex(p)) notifyListeners();
      _maybePrefetch(p);
    });
    _errorSub = _ap.errorStream.listen(_onPlayerError);
    // 桥那边出的错原本一个字节都不落地：接住它，日志和取证那一行才有得可看。
    _bridgeSub = AudioService.asyncError.listen(_onBridgeError);
  }

  /// 播放器进了 idle、又没有任何一条错误跟着来，界面上就是「歌自己停了，什么也没写」。
  ///
  /// 这一种最难转述：她只会说「放着放着就没声了」。这里做两件事：把这一停说出来，
  /// 并且把停住的位置留下（[_resumeAt]），省得她点「接着放」之后从头再听一遍。
  /// 接桥那一路（[_scheduleBridgeHeal]）只管下拉菜单那张卡，接不回声音，所以话里
  /// 不敢写「正在自己接回来」——原来那句就是这么写的，人等半天，歌没回来。
  /// 同一首只说一次，idle 会连着报好几遍。
  String? _idleNotedKey;

  /// 界面上那句提示要不要给一颗「接着放」：只有这种「停了、又没人报错」才要。
  bool get idleStopped => _idleNotedKey != null;

  void _tellIfIdleStopped() {
    final song = current;
    if (song == null || busy || _netRetry != null || error != null) return;
    final key = LibraryStore.keyOf(song);
    if (_idleNotedKey == key) return;
    _idleNotedKey = key;
    // 位置存下来给「接着放」用；对不上这首歌，playAt 自己会把它当没这回事。
    if (_lastHeard > Duration.zero) {
      _resumeAt = _lastHeard;
      _resumeKey = key;
    }
    notice = '「${_t(song)}」中途停了';
    noticeTick++;
    AppLog.add('播', '播放器进 idle 且无报错：「${_t(song)}」（停在 ${_mm(_lastHeard)}）');
    notifyListeners();
  }

  void _onBridgeError(Object e) {
    _bridgeErrors++;
    // 只留头一条：桥断了之后每条状态都撞同一处，第一条才是那一下真正的原因。
    _firstBridgeError ??= _clip('$e');
    // 桥一旦断了会一路报错，全记会把日志那一页挤满；留下头几条和每五十条一次就够定位。
    if (_bridgeErrors <= 5 || _bridgeErrors % 50 == 0) {
      AppLog.add('卡', '第 $_bridgeErrors 次桥接报错 · ${humanizeError(e)}');
    }
    // 报错最常见的样子是原生那一侧的服务对象已经没了（setState 撞到 null），
    // 下一次状态推送就是把卡贴回来的机会 —— 前提是那座桥先接回去。
    if (_ap.playing) _scheduleBridgeHeal('桥连着报错');
  }

  static String _clip(String s) => s.length <= 90 ? s : '${s.substring(0, 90)}…';

  /// 播放中途被掐断走的是这条流，不是 [playAt] 的 catch：息屏后系统收回网络、CDN
  /// 半路断流、预取留下的半截文件都会在这里冒出来，而原来没人听它 —— 于是界面上
  /// 既没有报错也没有等待提示，她的感受就是「歌自己停了，也不知道为什么」。
  ///
  /// 已经听过几秒的非本地文件按断流处理：记住位置、扔掉手上这条地址，交给等一等
  /// 重试那条路，恢复后接着原处放。剩下的（下载的文件放不出、真的没有免费版）
  /// 等回来也一样，直接把话说清楚。
  void _onPlayerError(PlayerException e) {
    // 还在加载中（busy）的错误不归这条流管：那一次 `setAudioSource` 自己会抛，
    // 由 [playAt] 的 catch 处理。两边都接就等于同一次失败报两遍、重试排两队，
    // 而此刻 `current` 已经指向新歌，旧源残留的位置还会被记到新歌头上。
    if (busy) return;
    final song = current;
    if (song == null || _ap.processingState == ProcessingState.idle) return;
    final pos = _lastHeard > _ap.position ? _lastHeard : _ap.position;
    if (pos >= _resumeFloor && !LibraryStore.instance.hasLocalFile(song)) {
      _resumeAt = pos;
      _resumeKey = LibraryStore.keyOf(song);
      AppLog.add('播', '「${_t(song)}」在第 ${_mm(pos)} 断流，记住位置等重连');
      _urlStaler?.call(song, AppSettings.instance.quality);
      AudioPrefetch.instance.drop(song);
      if (_retryOnStreamDrop(_generation)) return;
    }
    // 从头就没打开过：手上这条地址本身是坏的（签名过期、被 CDN 拦下、换源记住的
    // 那个版本其实放不出）。以前只报错、缓存照旧——下一次还是同一条坏地址，
    // 这一首从此就放不出来了。
    if (pos < _resumeFloor && _retryWithFreshSource(song)) return;
    failedSong = song;
    error = humanizeError(e);
    _lastFailVip = looksLikeVipWall(error);
    AppLog.add('播', '「${_t(song)}」放不出：$error');
    if (_failStreak == 0) errorTick++;
    notifyListeners();
  }

  /// 把这条坏地址从所有缓存里抹掉，重取一条再放一次。返回 true 表示已安排重取。
  ///
  /// 清缓存和重取分开看：就算这一次不重取（已经重取过一轮，那首是真放不出），
  /// 坏地址也不能留着——不然她手动点「重试」拿到的还是同一条，这首从此就废了。
  bool _retryWithFreshSource(Song song) {
    if (LibraryStore.instance.hasLocalFile(song)) return false;
    LibraryStore.instance.forgetSwapSong(song);
    _urlStaler?.call(song, AppSettings.instance.quality);
    AudioPrefetch.instance.drop(song);
    // 一次播放只自动重来这一回：那 5/15/30/60 秒的等待是给断网留的，
    // 一条打不开的地址等再久也不会自己变好，重取才是对症的那一步。
    if (_sourceRetryGen == _generation) return false;
    // [retry] 走 [playAt]，序号当场 +1：记下重取那一趟的序号，它要还是打不开，
    // 就说明换一条地址也救不了这首，按正常失败往下走（记错误、跳下一首）。
    _sourceRetryGen = _generation + 1;
    notice = '这条音频地址没打开，重取一条再放一次';
    noticeTick++;
    AppLog.add('试', '「${_t(song)}」地址没打开，忘掉记住的版本重取一条');
    notifyListeners();
    unawaited(retry());
    return true;
  }

  /// Replace the queue and start from [start]. The only entry point pages need.
  Future<void> playList(List<Song> songs, int start) async {
    if (songs.isEmpty) return;
    _failStreak = 0;
    // 「播完这首就停」是给上一段的收尾用的，她重新挑了一整条队列就该跟着清掉，
    // 否则新歌单第一首放完就哑了。
    _stopAfterCurrent = false;
    // 她重新挑了一整条队列，上一首断流留下的位置就此作废：从这一行的开头播才对得上意图。
    _resumeAt = null;
    _resumeKey = null;
    queue
      ..clear()
      ..addAll(songs);
    final from = start.clamp(0, songs.length - 1);
    AppLog.add('播', '换了队列：${songs.length} 首，从「${_t(songs[from])}」开始');
    _scanVip(queue, from);
    await playAt(from);
  }

  /// 集中处理会员墙：整队列里那些墙后面的歌一次性去后台找免费版本，
  /// 找到就落盘，之后播到那首第一步就命中，不用一首等二十秒。
  ///
  /// 只在队列刚换完时排一次；查询串行，一轮没跑完又来新一轮时旧的那轮会被
  /// [VipScanner] 的 cancelled 判掉提前收工——她连点三个歌单，不该发三批搜索。
  /// 单次最多 [_vipScanMax] 首，超出说明这一整片都要换源，一次几十首连着发出去
  /// 容易被风控，那种留给列表页的体检按钮。
  static const _vipScanMax = 20;
  int _vipScanGen = 0;
  Future<void> _vipScanTail = Future<void>.value();

  void _scanVip(List<Song> songs, int from) {
    if (!AppSettings.instance.vipAutoScan) return;
    final scanner = _vipScanner;
    if (scanner == null) return;
    final gen = ++_vipScanGen;
    // 从当前这首往后排：离播放位置越近越先查，被上限砍掉的该是最远的那些。
    final ordered = [...songs.sublist(from), ...songs.sublist(0, from)];
    // 排除了 QQ 的会员歌就等于漏掉一整批：它们撞的是同一堵墙，也靠同一条换源链子救。
    final todo = ordered.where((s) => s.twinBlocked).take(_vipScanMax).toList();
    if (todo.isEmpty) return;
    _vipScanTail = _vipScanTail.then((_) async {
      // 排队期间她可能又换了队列，这一轮整批作废。
      if (gen != _vipScanGen) return;
      late final ({int fixed, int dead, int total}) r;
      try {
        r = await scanner(todo, cancelled: () => gen != _vipScanGen);
      } catch (_) {
        return;
      }
      if (gen != _vipScanGen) return;
      if (r.total > 0) {
        AppLog.add('补', '整单补测 ${r.total} 首会员歌：备好 ${r.fixed} 首，${r.dead} 首确实没有');
      }
      if (r.fixed == 0 && r.dead == 0) return; // 一首都没换到，别打扰
      notice = r.fixed > 0
          ? '${r.fixed} 首会员歌已备好免费版本'
          : '这 ${r.total} 首会员歌确实没有免费版本，播到时会直接跳过';
      noticeTick++;
      notifyListeners();
    });
  }

  /// Play the queue item at [i], fetching its URL only when it is needed.
  Future<void> playAt(int i) async {
    if (i < 0 || i >= queue.length) return;
    // 切走的这一刻先给上一首记一笔账：她听到第几秒就走了，是口味最直接的信号，
    // 而全App只有这里知道那一刻。自然播完的那首已经在 [_onTrackEnd] 记过，跳过。
    final out = current;
    final outHeard = _lastHeard;
    final gen = ++_generation;
    index = i;
    busy = true;
    error = null;
    lyric = [];
    lyricBusy = true;
    lyricIndex = -1;
    _prefetchFor = -1;
    _randomPick = null;
    notifyListeners();
    final song = queue[i];
    if (out != null &&
        LibraryStore.keyOf(out) != LibraryStore.keyOf(song) &&
        LibraryStore.keyOf(out) != _endNoted) {
      _noteHeard(out, heard: outHeard, completed: false);
    }
    _endNoted = null;
    // 断流留下的位置只对那一首、那一次重试有用：对不上号就先清掉，用掉之后再清一次，
    // 免得她下次主动重听同一首被接到半路去。对得上时先不消费 —— 网络还没回来时
    // 这里会连着失败好几轮，每轮都值得用同一个位置接着放。
    final resume = _resumeKey == LibraryStore.keyOf(song) ? _resumeAt : null;
    if (resume == null) {
      _resumeAt = null;
      _resumeKey = null;
      // 另起一首就该把重试额度重新发一遍：上一首把四轮全烧光，这一首一次都没试过
      // 就被判死，跳过去的其实是一首好好的歌。
      _netRetries = 0;
    }
    _lastHeard = Duration.zero;
    // 换了一首就是新的一分钟：上一首拖到的那个目标不该再压着这一首的进度头。
    _seekHold = null;
    // 重新开播就是「她自己接回来了」：那句「中途停了」和它那颗键该一起收走，
    // 同一首下次再停在半路也还要能说一次。
    _idleNotedKey = null;
    if (resume != null) AppLog.add('播', '「${_t(song)}」要从 ${_mm(resume)} 接着放');
    // 有没有拿到地址，决定失败该按哪条路收拾：拿不到是取链的问题（会员墙、真的没有免费版），
    // 重取同一条链子还是拿不到；拿到了却放不出，才是那条地址本身坏了。
    var gotUrl = false;
    try {
      final source = await _sourceFor(song).timeout(const Duration(seconds: 30));
      if (gen != _generation) return;
      gotUrl = true;
      // 取到链接不等于放得出来：音源脚本卡住或平台层不回应时，没有超时就永远
      // 停在「加载中」，自动跳下一首也永远不会触发。
      // 续播那一趟要慢得多：Exo 得先把缓冲推到第几分钟才回话，用从零起播那 15 秒
      // 去卡它，恰好会在最不该失败的地方失败。
      await _ap
          .setAudioSource(source, initialPosition: resume)
          .timeout(Duration(seconds: resume != null ? 45 : 15));
      _resumeAt = null;
      _resumeKey = null;
      AppLog.add('播', '「${_t(song)}」开始播放（第 ${_mm(resume ?? Duration.zero)}，$_how）');
      if (_speed != 1.0) {
        try {
          await _ap.setSpeed(_speed);
        } catch (_) {}
      }
      _failStreak = 0;
      _netRetries = 0;
      failedSong = null;
      // 续播成功不该再记一笔「开播」：第一次放出去那回已经记过了。重连一轮记一次，
      // 一首歌能凭空攒出四五次播放，而口味是按次数加权的 —— 听着听着就把还在听的
      // 这首误判成听厌了。
      if (resume == null) LibraryStore.instance.recordRecent(song);
      unawaited(_loadLyric(song, gen));
      unawaited(_restoreEq());
      // 手动切歌不该从零跑整条链子：开播这一刻就把后面那两首备好。
      _warmUpcoming();
      await _ap.play();
    } catch (e) {
      if (gen != _generation) return;
      if (_retryOnNetworkLoss(e, gen)) return;
      // 地址拿到了却放不出去：这条链接本身是坏的（过期/风控），换一条才对症。
      // 取链那一步就失败的（会员墙、真的没有免费版）不归这里，重取还是同一条链子。
      if (gotUrl && _retryWithFreshSource(song)) return;
      failedSong = song;
      error = humanizeError(e);
      _lastFailVip = looksLikeVipWall(error);
      AppLog.add('链', '「${_t(song)}」取不到声音：$error');
      // 一路跳歌时只报第一次：现在一首失败到下一首只要一秒多，每首都弹一条
      // 就成了刷屏。播放页上那句错误说明照旧留着。
      if (_failStreak == 0) errorTick++;
      _scheduleAutoSkip(gen);
    } finally {
      if (gen == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// 连不上网时停在当前这首等一等，而不是把队列跳过去。返回 true 表示已安排重试。
  bool _retryOnNetworkLoss(Object e, int gen) {
    if (!looksLikeNetworkFailure(e)) return false;
    return _waitAndRetry(gen, first: '网络断了，恢复后会自动接着放');
  }

  /// 断流重连。Exo 回来的只有一句 `source error`，写不出「连不上」的字样，
  /// 但表现一模一样，所以这里不按错误文本判，只看「确实播出去过几秒」。
  bool _retryOnStreamDrop(int gen) => _waitAndRetry(gen, first: '播放断流了，恢复后会自动接着放');

  /// 等一等再重试当前这一首：间隔逐次拉长，[_netRetryDelays.length] 轮还不行才认输，
  /// 让调用方接着走原来的路（报错 / 跳下一首）。
  bool _waitAndRetry(int gen, {required String first}) {
    if (_netRetries >= _netRetryDelays.length) return false;
    final secs = _netRetryDelays[_netRetries++];
    notice = _netRetries == 1 ? first : '$secs 秒后再试一次';
    AppLog.add('试', '第 $_netRetries 次重连：等 $secs 秒（$first）');
    noticeTick++;
    notifyListeners();
    _netRetry?.cancel();
    _netRetry = Timer(Duration(seconds: secs), () {
      // 到点就不等了：这一句是给「还在等」用的，先摘掉再决定要不要重试，
      // 免得重试那一趟正在跑、界面上还挂着「在等网络回来」。
      _netRetry = null;
      // 她随时可能自己点了别的歌，序号对不上就当这次作废。
      if (gen != _generation) return;
      unawaited(retry());
    });
    return true;
  }

  /// NetEase hides roughly half of any hot list behind VIP, so a dead track must
  /// not look like a broken app: when the user allows it, move on by itself and
  /// give up loudly once the whole queue has been tried.
  /// 自动跳歌最多连着跳这么多首就停。两百首的队列挨个试到最后，她只能干等着：
  /// 连着十几首都放不出，结论已经是「这一片没有能播的版本」，不必再试剩下的。
  static const _skipStreakCap = 12;

  void _scheduleAutoSkip(int gen) {
    if (!AppSettings.instance.autoSkipFailed || queue.length < 2) return;
    _failStreak++;
    final whole = _failStreak >= queue.length;
    if (whole || _failStreak >= _skipStreakCap) {
      _failStreak = 0;
      final scope = whole ? '队列里的歌' : '连着 $_skipStreakCap 首歌';
      error = _lastFailVip
          ? '$scope都撞在会员墙上，暂时没有能播的版本；可在列表页「整单找免费版」再试'
          : '$scope都放不出来，多半是网络；跑一次「音源自检」能看出是哪个曲库不通';
      AppLog.add('跳', '$scope都放不出，停在这里：$error');
      // 不递增 errorTick 的话，main.dart 只认 tick 变化，这句话永远不会弹出来。
      errorTick++;
      notifyListeners();
      return;
    }
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (gen != _generation) return;
      AppLog.add('跳', '连着 $_failStreak 首放不出，跳到下一首');
      unawaited(next(manual: false));
    }));
  }

  /// Prefer a file this app already downloaded, so the song plays even with no
  /// network and no音源 round-trip. 其次是预取下来的下一首：整首已在磁盘上，
  /// 切过去和放本地文件一样快，不用再等一次建连缓冲。
  Future<AudioSource> _sourceFor(Song song) async {
    // 播放卡的封面必须先落到本地（理由见 artFileFor）。这一发和下面找音轨并行
    // 发起，打 tag 时多半已经回来，不给起播加时间。
    final art = artFileFor(artUrl(song.pic, px: 300));
    final local = LibraryStore.instance.localFile(song);
    if (local != null) {
      _how = '本机下载的文件';
      return AudioSource.file(local, tag: await _mediaItem(song, art));
    }
    final resolver = _urlResolver;
    if (resolver == null) throw Exception('播放组件还没就绪，请重启应用');
    final quality = AppSettings.instance.quality;
    // 档位按这条歌真正由哪个平台出声来算：换到 B 站的歌，磁盘上那份是 192k，
    // 拿设置里的无损去查永远查不到，白在线下一遍。
    final servedBy = LibraryStore.instance.swapSongFor(song)?.source;
    final pre = await AudioPrefetch.instance.path(song, quality, servedBy: servedBy);
    if (pre != null) {
      _how = '提前备好的 ${heardQuality(quality, servedBy ?? song.source)}';
      return AudioSource.file(pre, tag: await _mediaItem(song, art));
    }
    final url = await resolver(song, quality);
    // 日志里那一档要和播放页上的是同一句话：换到 B 站的歌写「现取无损」，
    // 对着日志排查时先把人带偏。
    _how = '现取 ${heardQuality(quality, LibraryStore.instance.swapSongFor(song)?.source ?? song.source)}';
    // 防盗链头按拿到的这条地址判，不按 `song.source`：换源给的是 B 站的音轨，
    // 队列里那一首却还写着网易云（不带 Referer 实测三成就 403）。
    return AudioSource.uri(
      Uri.parse(url),
      headers: BlSource.headersFor(url),
      tag: await _mediaItem(song, art),
    );
  }

  /// just_audio_background requires a MediaItem tag on every AudioSource — it
  /// is what the notification and lock screen show.
  ///
  /// [art] 是 [_sourceFor] 提前发起的那次下载，这里才等它：卡上的图只能给
  /// 本地文件路径，给 https 地址原生解不出来（永远只剩占位音符）。
  Future<MediaItem> _mediaItem(Song s, Future<String?> art) async {
    final file = await art;
    return MediaItem(
      id: '${s.source}:${s.songmid}',
      title: s.name.isEmpty ? '未知歌曲' : s.name,
      artist: s.singer.isEmpty ? '' : s.singer,
      album: s.albumName,
      duration: (s.interval ?? 0) > 0 ? Duration(seconds: s.interval!) : null,
      artUri: file == null ? null : Uri.file(file),
    );
  }

  Future<void> _loadLyric(Song song, int gen) async {
    final resolver = _lyricResolver;
    if (resolver == null) {
      lyricBusy = false;
      return;
    }
    lyricBusy = true;
    try {
      final payload = await resolver(song);
      if (gen != _generation || !identical(current, song)) return;
      lyric = LyricParser.merge(payload);
      lyricIndex = -1;
    } catch (_) {
    } finally {
      if (gen == _generation) {
        lyricBusy = false;
        notifyListeners();
      }
    }
  }

  /// 「暂无歌词」点一下重新取：接口偶发返回空，不该让她只能切歌再切回来。
  void reloadLyric() {
    final song = current;
    if (song == null) return;
    unawaited(_loadLyric(song, _generation));
    notifyListeners();
  }

  void _onTrackEnd() {
    if (queue.isEmpty) return;
    final cur = current;
    if (cur == null) return;
    // 听完比「点开过」强得多：整首都记上。位置取总时长，在线流的 duration
    // 有时不报，退回曲库里现成的那个 interval。
    _endNoted = LibraryStore.keyOf(cur);
    _noteHeard(cur, heard: total ?? _lastHeard, completed: true);
    // 「播完这首就停」排在循环模式之前：这是她此刻最明确的一句意愿，
    // 循环那种长期设定不该盖过来。
    if (_stopAfterCurrent) {
      _stopAfterCurrent = false;
      unawaited(_ap.pause());
      notice = '「${_t(cur)}」放完了，按你说的停下';
      noticeTick++;
      notifyListeners();
      return;
    }
    switch (playMode) {
      case PlayMode.single:
        if (LibraryStore.instance.hasLocalFile(cur)) {
          unawaited(_ap.seek(Duration.zero));
          unawaited(_ap.play());
          // 这一趟是重新开始听，不是上一趟的尾巴：留着「已经记过听完」这个标记，
          // 她从第二轮里跳走时那一半的收听位置就再也记不进口味了。
          _endNoted = null;
        } else {
          // 在线单曲循环要重新取链接：缓存里那条地址放一首歌的时间就过期了，
          // 只 seek 回零的话，循环到第二次多半静音或直接失败。
          unawaited(playAt(index));
        }
      case PlayMode.random:
        unawaited(playAt(_randomNextIndex()));
      case PlayMode.list:
        unawaited(playAt((index + 1) % queue.length));
      case PlayMode.none:
        if (index + 1 < queue.length) {
          unawaited(playAt(index + 1));
        } else {
          unawaited(_ap.pause());
        }
    }
  }

  /// 把「这首听到哪、听完了没有」交给曲库记账。
  ///
  /// 听不满十秒就跳走的不算信号：那多半是撞在放不出、或者她手滑点开又收回，
  /// 把它当成喜欢会把推荐一路带偏到一堆她其实没听进去的歌上。
  void _noteHeard(Song s, {required Duration heard, required bool completed}) {
    if (!completed && heard.inSeconds < 10) return;
    LibraryStore.instance.noteHeard(s, heardSeconds: heard.inSeconds, completed: completed);
  }

  int _randomOther() {
    if (queue.length <= 1) return index;
    var i = index;
    while (i == index) {
      i = _rnd.nextInt(queue.length);
    }
    return i;
  }

  /// 随机模式下「下一首是哪一首」提前摇定，而不是切歌那一刻才摇：
  /// 预取是按这一首下的整首，到点重摇的话，备好的货和真播的十有八九不是同一首
  /// ——白烧一条歌的流量，切过去还是要等整条链子。
  /// 记歌不记下表下标：她中途删一首，下标会挪位，歌不会。
  Song? _randomPick;

  Song _randomNextSong() {
    final picked = _randomPick;
    if (picked != null && queue.contains(picked) && !isCurrent(picked)) return picked;
    return _randomPick = queue[_randomOther()];
  }

  /// 随机模式接下来要播那一首的下标；队列只有一首时就是它自己。
  int _randomNextIndex() {
    if (queue.length < 2) return index;
    return queue.indexOf(_randomNextSong());
  }

  /// 当前这首的总时长。在线流的 duration 要等缓冲够才有，个别源甚至一直不报；
  /// 曲库里的 interval 是现成的。缺了这一层兜底，预取窗口永远算不出来，
  /// 下一首就永远不备货——听感上就是「每次切歌都要等」。
  ///
  /// 界面上那两条进度线也读这个：只认播放器那一份的话，开头几秒没有长度，
  /// 进度条整条变成一根转圈的模糊线，既拖不动也看不出这首歌还剩多久。
  Duration? get total {
    final d = duration;
    if (d != null && d > Duration.zero) return d;
    final sec = current?.interval ?? 0;
    return sec > 0 ? Duration(seconds: sec) : null;
  }

  /// 手动切歌的那一跳过去的是「她随时可能点的下一首、下下首」，而整首文件要等到
  /// 本曲快收尾才备。所以开播这一刻就把这两首的链接和歌词先取回来：取链子本身
  /// 要一两秒到十几秒，先跑掉的这次让真跳过去那一刻直接命中缓存，歌词也不会空一秒。
  /// 只取链接不下整首——整首要占带宽，正听着这首反而容易缓冲。
  void _warmUpcoming() {
    final url = _urlResolver;
    final lyric = _lyricResolver;
    if (url == null) return;
    final quality = AppSettings.instance.quality;
    for (final i in _upcomingIndexes()) {
      final s = queue[i];
      if (LibraryStore.instance.localFile(s) != null) continue;
      // 预取失败不做处理：真轮到它播放时还有一条完整重试的路。
      unawaited(url(s, quality).catchError((_) => ''));
      if (lyric != null) unawaited(lyric(s).catchError((_) => LyricResult(lyric: '')));
    }
  }

  /// 快播完时提前把后面那几首整首下到本地，并把歌词备好。放在临收尾而不是刚开播：
  /// 整首四五兆要占带宽，正听着的那首容易被它拖到缓冲；链接本身已经由 [_warmUpcoming]
  /// 先备好了，这里只是把下一首从「有链接」升级成「有文件」。
  ///
  /// 窗口给到 150 秒——90 秒在网络差一点的时候刚好差那一截，白等。
  void _maybePrefetch(Duration pos) {
    final total = this.total;
    if (total == null || _prefetchFor == index || total - pos > const Duration(seconds: 150)) return;
    _prefetchFor = index;
    final url = _urlResolver;
    final lyric = _lyricResolver;
    if (url == null || lyric == null) return;
    final quality = AppSettings.instance.quality;
    final upcoming = _upcomingIndexes();
    for (var n = 0; n < upcoming.length; n++) {
      final s = queue[upcoming[n]];
      // 预取失败不做任何处理：真轮到它播放时还有一条完整重试的路。
      // 问「备过没」要按这条歌真正的出声平台问：B 站那份存的是 192k 的键，
      // 拿设置里的无损去问永远问不出，每轮切歌都重新下一遍同样的字节。
      final servedBy = LibraryStore.instance.swapSongFor(s)?.source;
      if (LibraryStore.instance.localFile(s) == null &&
          !AudioPrefetch.instance.has(s, quality, servedBy: servedBy)) {
        // 亮屏时只整首备下一首：更靠后的随时会被跳过，白下不如不下。
        // 人已经走了（息屏/切走）就两首都备——后台网络随时会被省电策略掐掉，
        // 磁盘上有货才听得出「还在放歌」。
        final deep = _background ? upcoming.length : 1;
        if (n < deep) {
          unawaited(url(s, quality).then((u) => AudioPrefetch.instance.warm(
              s, quality, u,
              servedBy: LibraryStore.instance.swapSongFor(s)?.source ?? servedBy)).catchError((_) {}));
        }
      }
      unawaited(lyric(s).catchError((_) => LyricResult(lyric: '')));
    }
  }

  /// 手动切歌那一刻把后面那几首的整首备好。
  ///
  /// 常规备货排在「本曲快收尾」那一站，可手动跳过的人不等收尾：连着点三四首，
  /// 每一首都得现场取链、现场缓冲，听感就是「点一下空一秒」。跳完立刻补这一发，
  /// 下一跳就有现成文件；`preloadNext` 关着的话 [AudioPrefetch.warm] 自己会 return。
  void _deepWarm() {
    final url = _urlResolver;
    if (url == null) return;
    final quality = AppSettings.instance.quality;
    for (final i in _upcomingIndexes()) {
      final s = queue[i];
      final servedBy = LibraryStore.instance.swapSongFor(s)?.source;
      if (LibraryStore.instance.localFile(s) != null ||
          AudioPrefetch.instance.has(s, quality, servedBy: servedBy)) {
        continue;
      }
      unawaited(url(s, quality)
          .then((u) => AudioPrefetch.instance.warm(s, quality, u,
              servedBy: LibraryStore.instance.swapSongFor(s)?.source ?? servedBy))
          .catchError((_) {}));
    }
  }

  /// 按当前循环模式给出「接下来可能要放的」队列下标，最多两首。
  List<int> _upcomingIndexes() {
    if (queue.isEmpty || index < 0) return const [];
    if (playMode == PlayMode.single) return [index];
    if (playMode == PlayMode.random) return queue.length < 2 ? const [] : [_randomNextIndex()];
    if (queue.length < 2) return const [];
    final out = <int>[];
    for (var step = 1; step <= 2; step++) {
      final j = (index + step) % queue.length;
      if (j != index && !out.contains(j)) out.add(j);
    }
    return out;
  }

  Future<void> togglePlay() async {
    if (_ap.playing) {
      await _ap.pause();
    } else if (_ap.processingState == ProcessingState.completed && current != null) {
      await playAt(index);
    } else if (current != null) {
      await _ap.play();
    }
    notifyListeners();
  }

  Future<void> pause() => _ap.pause();
  Future<void> play() => _ap.play();

  /// 那张播放卡是进入播放态那一刻由播放服务贴到系统里的，Dart 侧看不见结果，
  /// 只能过一小会儿去问原生。晚三秒是别在建连缓冲那阵子多插一次通道调用。
  void _scheduleCardCheck({Duration after = const Duration(seconds: 3)}) {
    // 那张卡是安卓下拉菜单里的东西：桌面版没有通知、也没有那座桥。真去问一圈会得到
    // 「问不到播放卡的状态」，每放一首报一次，全是噪音。
    if (!Platform.isAndroid) return;
    _cardTimer?.cancel();
    _cardTimer = Timer(after, _checkMediaCard);
  }

  /// 回到前台时补看一次：卡被「一键清理」抹掉之后不会自己回来，
  /// 而她察觉到的第一现场往往就是这一瞬间。
  void recheckMediaCard() {
    if (isPlaying) _scheduleCardCheck();
  }

  /// 取证一行：原生那半截，加上我们这半截 —— 播放器想要什么状态、桥报过几次错、
  /// 头一次报的是什么。后两样原生问不到，而它们正好把「没告诉过服务要在放」和
  /// 「告诉了、死在桥里」分开，这两种病在她手机上看着一模一样：歌在放、有声音、
  /// 下拉那一格永远是空的。
  Future<MediaCardState> cardEvidence() async {
    final st = await PowerStatus.mediaCardState();
    return st.withBridge(_wantText(), _bridgeErrors, _firstBridgeError);
  }

  /// 我们自己这一侧的意愿。原来这里读的是插件的 `playbackStateStream`，后来查明
  /// 那条流只在旧版 backgroundTask 接法里才被喂数据，我们这条路读到的永远是出厂
  /// 默认值 —— 报出来会把人往错方向带，所以换成播放器的实际状态。
  String _wantText() => '=${_ap.playing}/${_ap.processingState.name}';

  /// 原生那半截桥被 idle 拆掉过，隔一会儿自己接回来。
  ///
  /// 不能在 idle 那一刻立刻接：原生收到 idle 只是 `stopSelf()`，服务真被销毁还要往后
  /// 排一队消息，接早了会被那次 onDestroy 再清一遍。晚两秒是给它走完的时间。
  void _scheduleBridgeHeal(String why, {Duration after = const Duration(seconds: 2)}) {
    _bridgeHeal?.cancel();
    _bridgeHeal = Timer(after, () => unawaited(_healBridge(why)));
  }

  /// 接桥。接好了顺手重贴一次卡：桥断那一刻媒体会话也被撤掉了（setActive(false) +
  /// 通知取消），光把 listener 装回去不会让那一格自己活过来，得再走一遍进入播放态。
  Future<void> _healBridge(String why, {bool force = false}) async {
    final r = await PowerStatus.reattachMediaListener();
    // alive = 桥压根没断（应用还在前台时服务被绑着，stopSelf 销毁不掉它）。
    // 这是常态，一行日志都不占。
    if (r == 'alive') return;
    AppLog.add('卡', '$why · 原生那半截桥${r == 'ok' ? '已经接回去' : '接不回去（原生答 $r）'}');
    if (r != 'ok' || !isPlaying) return;
    final now = DateTime.now();
    // 接桥本身不花钱，重贴卡却会把她正在听的那一首掐掉半秒，连着掐不行：
    // 自己动的手留 20 秒间隔，她按了按钮就是明确要求，不再拦。
    if (!force && now.difference(_lastBridgeRepost) < const Duration(seconds: 20)) return;
    _lastBridgeRepost = now;
    await repostCard();
  }

  Future<void> _checkMediaCard() async {
    final st = await cardEvidence();
    // 三秒里她可能已经停了：那时候「系统里没有卡」本来就该如此。
    if (!isPlaying) return;
    // 卡明明在、按钮却按不动 —— 就是这一项。修完这一处再看别的，两种病在屏幕上长得一样。
    if (st.listenerAlive == false) {
      AppLog.add('卡', '复查发现卡上的按钮没连着应用，接一次 · ${st.detail}');
      unawaited(_healBridge('复查'));
      return;
    }
    final verdict = st.verdict(playing: true);
    // 能自己修的先自己修，修好了就不弹提示：audio_service 只在进入播放态那一刻贴卡，
    // 被「一键清理」划掉之后不会自己回来，而暂停再播放正好逼它重贴一次。
    // 但刚开头那几秒不能动手：那一趟服务也许正走在发通知的路上，重贴只会把她刚开头的歌
    // 掐断半秒，什么也修不好。听到八秒还没卡就不是「还没走到」而是「走不到」了，
    // 所以这里先约好第二次复查，到点再自己逼一次。
    if (verdict == MediaCardVerdict.notPosted && !_cardRepaired) {
      if (position.inSeconds < 8) {
        _scheduleCardCheck(after: const Duration(seconds: 9));
        return;
      }
      _cardRepaired = true;
      AppLog.add('卡', '系统里没有播放卡，先自己重贴一次 · ${st.detail}');
      await repostCard();
      return;
    }
    if (verdict != MediaCardVerdict.notPosted) _cardRepaired = false;
    // 同一种毛病只报一次，修好了就把状态清掉，下次复发还能再报。
    if (verdict == cardProblem) return;
    cardProblem = verdict;
    // 只有真的开始放歌之后才查得到结果，所以这一行记的是状态变化，不是每次播放。
    final desc = switch (verdict) {
      MediaCardVerdict.notificationsOff => '系统把听歌小窝的通知关了，播放卡发不出去',
      MediaCardVerdict.channelBlocked => '「播放控制」那一栏被静默，播放卡发不出去',
      MediaCardVerdict.notificationsPaused => '手机开着「暂停通知」，通知这段时间全都不上屏',
      MediaCardVerdict.notPosted => '在放歌，系统里却没有播放卡',
      MediaCardVerdict.postedElsewhere => '播放卡在系统里，只是挂在另一栏上',
      MediaCardVerdict.hiddenByRom => '前台服务活着、通知却没上屏，被手机拦住了',
      MediaCardVerdict.inSystem => '播放卡已经在系统里（那一格还不显示就是手机的媒体模块没接上）',
      _ => '问不到播放卡的状态',
    };
    // 原始证据一并写进日志：导一次日志或截一张设置页就能定案，
    // 不用靠猜再来一轮、再让她重装一个包。「已经在系统里」那种没什么可取证的。
    AppLog.add('卡', verdict == MediaCardVerdict.inSystem ? desc : '$desc · ${st.detail}');
    // 卡片已经在系统里、那一格还不显示，剩下的是手机自己的媒体模块没接上 ——
    // 那不是弹个提示能解决的，设置页那一行会解释，这里不吵她。
    if (verdict != MediaCardVerdict.inSystem &&
        verdict != MediaCardVerdict.idle &&
        verdict != MediaCardVerdict.unknown) {
      cardTick++;
    }
    notifyListeners();
  }

  /// 让界面也能催一次接桥（设置页那一行上的「接回来」）。
  /// 她按了「接回来」就是明确要求，重贴卡那 20 秒的闸门不再拦（见 [_healBridge]）。
  Future<void> healBridge() => _healBridge('手动接桥', force: true);

  /// 暂停再播放逼播放服务重新贴一次卡（audio_service 只在进入播放态那一刻
  /// startForeground），也是让手机重新认一遍这个会话。
  Future<void> repostCard() async {
    if (!_ap.playing) return;
    await _ap.pause();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _ap.play();
    // 重发完再看一眼：真贴上了就别再提示，还是不行才拿得到下一条结论（比如被手机拦住了）。
    _scheduleCardCheck();
  }
  Future<void> seek(Duration d) async {
    // 拖进度条也是「她听到的位置」：不回写这里，往回拖之后万一断流，重连会把人送
    // 回拖动之前的那一秒，听起来就像歌自己乱跳了一段。
    _lastHeard = d;
    // 播放器接住这一跳要几百毫秒，在线流还得先把那一段缓冲回来。这期间位置流
    // 报的还是旧的点，进度头会先「弹回」原处再跳过去——看着就像没拖准。
    _seekHold = d;
    _seekHoldUntil = DateTime.now().add(const Duration(seconds: 10));
    await _ap.seek(d);
  }

  /// 拖过去之后、播放器真正到位之前的那个目标位置（见 [seek]）。
  Duration? _seekHold;
  DateTime _seekHoldUntil = DateTime(2000);
  Duration? get seekHold => _seekHold;

  void _releaseSeekHold(Duration p) {
    final h = _seekHold;
    if (h == null) return;
    final delta = p - h;
    final off = delta < Duration.zero ? -delta : delta;
    // 追上就交回真实位置；一直追不上（拖进还没缓冲的末尾、那次 seek 干脆失败）
    // 也不能把进度头悬在假位置上，十秒后同样交回去。
    if (off <= const Duration(seconds: 3) || DateTime.now().isAfter(_seekHoldUntil)) {
      _seekHold = null;
    }
  }
  Future<void> setVolume(double v) => _ap.setVolume(v);

  Future<void> setSpeed(double v) async {
    if (!speeds.contains(v) || v == _speed) return;
    _speed = v;
    AppSettings.instance.setPlaybackSpeed(v);
    try {
      await _ap.setSpeed(v);
    } catch (_) {
      // 个别平台实现不支持倍速，不因此打断播放
    }
    notifyListeners();
  }

  /// 切到下一首。`manual` 是「她点的」还是「放不出自己跳的」——前者要顺手把后面的歌
  /// 整首都备下来（见 [_deepWarm]），后者正撞在网络差的时候，别再抢带宽。
  Future<void> next({bool manual = true}) async {
    if (queue.isEmpty) return;
    final i = playMode == PlayMode.random ? _randomNextIndex() : (index + 1) % queue.length;
    await playAt(i);
    if (manual && _failStreak == 0) _deepWarm();
  }

  /// 上一首。已经听到 3 秒之后时先回到本曲开头，这跟系统音乐应用一致，
  /// 想重听副歌不用先跳过整首。
  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final i = index - 1 < 0 ? queue.length - 1 : index - 1;
    await playAt(i);
    if (_failStreak == 0) _deepWarm();
  }

  /// Retry whatever just failed.
  Future<void> retry() => playAt(index);

  /// 提示条上那颗「重试」。
  ///
  /// 要认 [failedSong] 而不是「现在屏幕上这首」：放不出之后自动跳到下一首只要一秒多，
  /// 她读完那句话抬手去点，点到的却是另一首歌——想重来的那首还留在原地没动。
  Future<void> retryFailed() async {
    final f = failedSong;
    if (f != null) {
      final i = queue.indexWhere((s) => LibraryStore.keyOf(s) == LibraryStore.keyOf(f));
      if (i >= 0 && i != index) {
        await playAt(i);
        return;
      }
    }
    await playAt(index);
  }

  /// 卡上切歌那一下包一层：动作就是界面里那两个键的 [action]，这里只多记一行
  /// 「她是按了卡」，并把异常接住 —— 让它逃进 media 通道只会换成一次错误回执，
  /// 日志上什么都看不见。
  Future<void> Function() _cardSkip(Future<void> Function() action, String label) {
    return () async {
      if (_background) AppLog.add('卡', '卡上按了$label');
      try {
        await action();
      } catch (e) {
        AppLog.add('卡', '卡上$label没走通 · ${humanizeError(e)}');
      }
    };
  }

  Future<void> stopAndClear() async {
    _generation++;
    // 队列清空了，后台那批「找免费版」也就没意义了。
    _vipScanGen++;
    // 只能暂停，不能 stop：once 播放器进 idle，audio_service 就把整个前台服务
    // 停掉、并把 Dart 侧的 listener 置空（AudioService.java:565 和 :360-384）。
    // 之后服务被系统重建时卡还能贴出来，但每个按钮都落在 null listener 上——
    // 界面点得动、卡上点了没反应，而且 Dart 侧没有任何补救办法。
    await _ap.pause();
    _netRetry?.cancel();
    _netRetry = null;
    _netRetries = 0;
    _resumeAt = null;
    _resumeKey = null;
    _lastHeard = Duration.zero;
    _seekHold = null;
    _idleNotedKey = null;
    // 这一首已经记过「听完」，但那笔账属于上一段收听。留着它，下次在这首歌上
    // 听到一半跳走就不再记账了 —— 曲库只会越听越少地漏掉信号。
    _endNoted = null;
    AudioPrefetch.instance.cancelRunning();
    queue.clear();
    index = -1;
    lyric = [];
    lyricBusy = false;
    lyricIndex = -1;
    _prefetchFor = -1;
    _randomPick = null;
    error = null;
    busy = false;
    // 队列都撤了，「播完这首就停」「再定一次」这两句就不该还挂着：
    // 下一批歌是另一件事，不该被上一段睡前的意愿管着。
    _stopAfterCurrent = false;
    sleepJustEnded = false;
    notifyListeners();
  }

  void addToQueue(Song song) {
    queue.add(song);
    if (index < 0) {
      unawaited(playAt(queue.length - 1));
      return;
    }
    notifyListeners();
  }

  void addAllToQueue(Iterable<Song> songs) {
    queue.addAll(songs);
    notifyListeners();
  }

  Future<void> removeFromQueue(int i) async {
    if (i < 0 || i >= queue.length) return;
    final isCurrent = i == index;
    queue.removeAt(i);
    if (queue.isEmpty) {
      await stopAndClear();
      return;
    }
    if (i < index) index--;
    notifyListeners();
    if (isCurrent) await playAt(i.clamp(0, queue.length - 1));
  }

  /// 撤销「从队列移除」：放回原来的位置。
  ///
  /// 移除正在播的那首时，[removeFromQueue] 已经把 index 停在同一格（原来的下一首），
  /// 所以从 <= index 的位置插回去都要把当前往后挪一格，高亮才不会跟着跑。
  void reinsertInQueue(int i, Song song) {
    if (i < 0 || i > queue.length) return;
    queue.insert(i, song);
    if (i <= index) index++;
    notifyListeners();
  }

  /// Queue this song right after whatever is playing (网易云「下一首播放」).
  void playNext(Song song) {
    if (index < 0) {
      queue.add(song);
      unawaited(playAt(queue.length - 1));
      return;
    }
    queue.insert(index + 1, song);
    notifyListeners();
  }

  /// 用另一个版本顶替放不出的那首歌。
  ///
  /// 它正在播就原地换掉重新起播，在队列里别处就换掉不动当前，不在队列里
  /// 就当「下一首播放」——三种落点都不该把整条队列清掉。
  Future<void> playInsteadOf(Song origin, Song replacement) async {
    final i = queue.indexWhere((s) => s.source == origin.source && s.songmid == origin.songmid);
    if (i < 0) {
      playNext(replacement);
      return;
    }
    queue[i] = replacement;
    if (i != index) {
      notifyListeners();
      return;
    }
    await playAt(i);
  }

  /// Reorder within the queue while keeping the playing song highlighted.
  /// [to] is the post-removal index, which is what ReorderableListView's
  /// onReorderItem reports.
  void moveInQueue(int from, int to) {
    if (from < 0 || from >= queue.length) return;
    final playing = current;
    final song = queue.removeAt(from);
    queue.insert(to.clamp(0, queue.length), song);
    if (playing != null) index = queue.indexOf(playing);
    notifyListeners();
  }

  /// Countdown to pause playback — the bedtime feature every music app has.
  void setSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _lastSleep = d;
    sleepJustEnded = false;
    _sleepEndsAt = DateTime.now().add(d);
    _sleepTimer = Timer(d, _onSleepElapsed);
    // Repaint the remaining-time label without a per-second ticker storm.
    _sleepTick = Timer.periodic(const Duration(seconds: 20), (_) => notifyListeners());
    notice = '将在 ${d.inMinutes} 分钟后停止播放';
    noticeTick++;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _sleepTimer = null;
    _sleepTick = null;
    if (_sleepEndsAt == null) return;
    _sleepEndsAt = null;
    // 按了总得回一句：原来这一条只是让屏幕上那个倒计时消失，
    // 到底是取消了还是又出别的事，屏幕上没有任何说法。
    notice = '定时已取消，这一轮会一直播下去';
    noticeTick++;
    notifyListeners();
  }

  void _onSleepElapsed() {
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepEndsAt = null;
    unawaited(_ap.pause());
    sleepJustEnded = true;
    notice = '定时播放已到点，已停止';
    noticeTick++;
    notifyListeners();
  }

  /// 定时到点停下了，但「再听半小时」是常事：提示条上直接给一次续，
  /// 别让她再去更多菜单里翻那一排分钟数。
  bool sleepJustEnded = false;
  Duration _lastSleep = const Duration(minutes: 30);

  /// 上一次定的多长，给「再定一次」和菜单里的当前勾选用。
  Duration get lastSleep => _lastSleep;

  void rearmSleepTimer() {
    sleepJustEnded = false;
    setSleepTimer(_lastSleep);
  }

  /// 「播完当前这首停止」：不想掐表、只想让手里这一首是最后一首。
  bool _stopAfterCurrent = false;
  bool get stopAfterCurrent => _stopAfterCurrent;

  void toggleStopAfterCurrent() {
    _stopAfterCurrent = !_stopAfterCurrent;
    notice = _stopAfterCurrent ? '这首放完就停止播放' : '「播完这首就停」已经取消';
    noticeTick++;
    notifyListeners();
  }

  bool get sleepActive => _sleepEndsAt != null;
  Duration get sleepRemaining {
    final ends = _sleepEndsAt;
    if (ends == null) return Duration.zero;
    final left = ends.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void cyclePlayMode() {
    playMode = switch (playMode) {
      PlayMode.list => PlayMode.single,
      PlayMode.single => PlayMode.random,
      PlayMode.random => PlayMode.none,
      PlayMode.none => PlayMode.list,
    };
    // 存下来：这个选择是关于「她平时怎么听」的，不是这一次队列的。以前只活在内存里，
    // 想用随机听一整晚，每次重开应用都得先点回随机。
    AppSettings.instance.setPlayMode(playMode.name);
    notifyListeners();
  }

  String get playModeLabel => switch (playMode) {
        PlayMode.list => '列表循环',
        PlayMode.single => '单曲循环',
        PlayMode.random => '随机播放',
        PlayMode.none => '播完停止',
      };

  IconData get playModeIcon => switch (playMode) {
        PlayMode.list => Icons.repeat,
        PlayMode.single => Icons.repeat_one,
        PlayMode.random => Icons.shuffle,
        PlayMode.none => Icons.stop_circle_outlined,
      };

  void setLyric(String raw) {
    lyric = LyricParser.parse(raw);
    lyricIndex = -1;
    notifyListeners();
  }

  /// Returns true when the active lyric line moved, so callers repaint only on
  /// a real change instead of every position tick.
  bool _updateLyricIndex(Duration pos) {
    final ms = pos.inMilliseconds;
    var next = -1;
    for (var i = lyric.length - 1; i >= 0; i--) {
      if (lyric[i].timeMs <= ms) {
        next = i;
        break;
      }
    }
    if (next == lyricIndex) return false;
    lyricIndex = next;
    return lyric.isNotEmpty;
  }

  Duration lyricPosition(int i) =>
      (i >= 0 && i < lyric.length) ? Duration(milliseconds: lyric[i].timeMs) : Duration.zero;

  /// Whether the platform exposes a parametric EQ (Android only today).
  Future<bool> eqSupported() async {
    // 桌面版连那条通道都没有，答案先写好，不用等一次注定失败的调用。
    if (!Platform.isAndroid) return false;
    try {
      final params = await _eq.parameters.timeout(const Duration(seconds: 3));
      return params.bands.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> applyPreset(EqPreset preset) async {
    try {
      final params = await _eq.parameters.timeout(const Duration(seconds: 3));
      if (params.bands.isEmpty) {
        // 一台机上的均衡器有 0 个频段是有可能的（某些定制 ROM 就这样）：
        // 这时候「启用」按下去只会静默成功，什么都不会变。
        eqError = '这台机的均衡器没有给出任何频段，预设挂不上去';
        notifyListeners();
        return;
      }
      await _eq.setEnabled(true);
      final gains = _resampleGains(preset.gains, params.bands.length);
      for (var i = 0; i < params.bands.length; i++) {
        final g = gains[i].clamp(params.minDecibels, params.maxDecibels);
        await params.bands[i].setGain(g);
      }
      eqPresetName = preset.name;
      eqGains = gains;
      eqError = null;
      AppSettings.instance.setEqPreset(preset.name);
      notifyListeners();
    } catch (e) {
      // 原来这里整个吞掉：开关自己弹回去就算「失败了」，
      // 到底是手机不让挂、还是系统那条通道没应答，屏幕上没有任何说法。
      eqError = '这一档音效没能挂上：${humanizeError(e)}';
      notifyListeners();
    }
  }

  Future<void> disableEq() async {
    try {
      await _eq.setEnabled(false);
      eqPresetName = '关闭';
      eqError = null;
      AppSettings.instance.setEqPreset('关闭');
      notifyListeners();
    } catch (e) {
      eqError = '没能关掉均衡器：${humanizeError(e)}';
      notifyListeners();
    }
  }

  /// 重启后第一次真正接上音源时，把存下来的预设补回去。
  /// 只在第一首做一次：之后都是同一个播放器实例，效果器一直挂着。
  Future<void> _restoreEq() async {
    if (_eqRestored) return;
    _eqRestored = true;
    final name = AppSettings.instance.eqPreset;
    if (name == '关闭') return;
    for (final p in eqPresets) {
      if (p.name == name) {
        await applyPreset(p);
        return;
      }
    }
  }

  static List<double> _resampleGains(List<double> src, int n) {
    if (src.length == n) return src;
    if (n <= 0) return const [];
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final pos = n == 1 ? 0.0 : i * (src.length - 1) / (n - 1);
      final lo = pos.floor().clamp(0, src.length - 1);
      final hi = pos.ceil().clamp(0, src.length - 1);
      final t = pos - lo;
      out[i] = src[lo] * (1 - t) + src[hi] * t;
    }
    return out;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _cardTimer?.cancel();
    _bridgeHeal?.cancel();
    _netRetry?.cancel();
    unawaited(_stateSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_bridgeSub?.cancel());
    // 留着播放器实例不 dispose：`AudioPlayer.dispose()` 头一步就是 stop()，
    // 那一下会把 idle 发出去，前台服务跟着被停、桥那头的 listener 被清空
    // ——界面还在，卡上的键从此全空转。这个进程本来就只有退出时才需要收回播放器，
    // 而那时候系统连同服务一起收走。
    super.dispose();
  }
}
