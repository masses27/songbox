import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart' show MediaItem;

import '../library/library_store.dart';
import '../models/results.dart';
import '../models/song.dart';
import '../music_sdk/bl_source.dart';
import '../settings/app_settings.dart';
import '../util/app_log.dart';
import '../util/art_url.dart';
import '../util/humanize.dart';
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
  const EqPreset(this.name, this.gains);
}

const eqPresets = <EqPreset>[
  EqPreset('平坦', [0, 0, 0, 0, 0]),
  EqPreset('重低音', [8, 5, 0, -2, -1]),
  EqPreset('清晰人声', [-2, 0, 4, 3, 1]),
  EqPreset('流行', [3, 1, -1, 2, 4]),
  EqPreset('摇滚', [5, 2, -1, 3, 4]),
  EqPreset('古典', [4, 2, 0, 2, 3]),
  EqPreset('电子', [6, 3, -1, 2, 5]),
  EqPreset('柔和', [2, 1, 0, 1, 2]),
  EqPreset('低音减弱', [-4, -2, 0, 1, 2]),
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

  final AndroidEqualizer _eq = AndroidEqualizer();
  late final AudioPlayer _ap =
      AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [_eq]));

  final List<Song> queue = [];
  int index = -1;
  List<LyricLine> lyric = [];
  int lyricIndex = -1;
  PlayMode playMode = PlayMode.list;
  String eqPresetName = '平坦';
  List<double> eqGains = const [0, 0, 0, 0, 0];
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

  /// 断流时 [_ap] 的 position 有可能已经被清回零，所以边播边把最后听到的位置留着。
  Duration _lastHeard = Duration.zero;

  /// 自然播完的那首已经在 [_onTrackEnd] 记过账，紧跟着那一次 [playAt] 别再把它
  /// 记成「听到一半跳走」—— 一次播放只该记一次。
  String? _endNoted;

  /// 人已经不在应用里了（息屏、切走）。这时候系统随时可能掐掉后台网络，所以本地
  /// 备着的歌就是唯一的保险，多备一首值得。
  bool _background = false;

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
    // 预取目录里还留着上次下的整首，先扫进内存表：这趟磁盘往返不该排在第一次切歌前面。
    unawaited(AudioPrefetch.instance.prime());
    _speed = speeds.contains(AppSettings.instance.playbackSpeed) ? AppSettings.instance.playbackSpeed : 1.0;
    // 效果器随播放器实例一起没了，界面先按存下来的名字显示，第一首再接上真值。
    final savedEq = AppSettings.instance.eqPreset;
    eqPresetName = savedEq == '关闭' || eqPresets.any((p) => p.name == savedEq) ? savedEq : '关闭';
    _stateSub = _ap.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) _onTrackEnd();
    });
    _playingSub = _ap.playingStream.listen((_) => notifyListeners());
    _positionSub = _ap.positionStream.listen((p) {
      if (_ap.playing) _lastHeard = p;
      if (_updateLyricIndex(p)) notifyListeners();
      _maybePrefetch(p);
    });
    _errorSub = _ap.errorStream.listen(_onPlayerError);
  }

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
      AudioPrefetch.instance.drop(song, AppSettings.instance.quality);
      if (_retryOnStreamDrop(_generation)) return;
    }
    failedSong = song;
    error = humanizeError(e);
    _lastFailVip = looksLikeVipWall(error);
    AppLog.add('播', '「${_t(song)}」放不出：$error');
    if (_failStreak == 0) errorTick++;
    notifyListeners();
  }

  /// Replace the queue and start from [start]. The only entry point pages need.
  Future<void> playList(List<Song> songs, int start) async {
    if (songs.isEmpty) return;
    _failStreak = 0;
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
    final todo = ordered.where((s) => s.needsVip).take(_vipScanMax).toList();
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
    if (resume != null) AppLog.add('播', '「${_t(song)}」要从 ${_mm(resume)} 接着放');
    try {
      final source = await _sourceFor(song).timeout(const Duration(seconds: 30));
      if (gen != _generation) return;
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
      // 链接取到了却放不出来（过期/风控），把它从缓存里扔掉，重试才会拿新的。
      if (LibraryStore.instance.localFile(song) == null) {
        _urlStaler?.call(song, AppSettings.instance.quality);
      }
      // 预取那份也可能就是坏的（断流留下的半截），一起扔。
      AudioPrefetch.instance.drop(song, AppSettings.instance.quality);
      if (_retryOnNetworkLoss(e, gen)) return;
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
      unawaited(next());
    }));
  }

  /// Prefer a file this app already downloaded, so the song plays even with no
  /// network and no音源 round-trip. 其次是预取下来的下一首：整首已在磁盘上，
  /// 切过去和放本地文件一样快，不用再等一次建连缓冲。
  Future<AudioSource> _sourceFor(Song song) async {
    final local = LibraryStore.instance.localFile(song);
    if (local != null) {
      _how = '本机下载的文件';
      return AudioSource.file(local, tag: _mediaItem(song));
    }
    final resolver = _urlResolver;
    if (resolver == null) throw Exception('播放组件还没就绪，请重启应用');
    final quality = AppSettings.instance.quality;
    final pre = await AudioPrefetch.instance.path(song, quality);
    if (pre != null) {
      _how = '提前备好的 $quality';
      return AudioSource.file(pre, tag: _mediaItem(song));
    }
    final url = await resolver(song, quality);
    _how = '现取 $quality';
    // B 站的音频直链要带 Referer，不带实测大约三成就 403；其他源的地址多这个头没影响，
    // 所以只在 bl 这一档加，别把播放路径上凭空多出的代理算子留给所有人。
    return AudioSource.uri(Uri.parse(url),
        headers: song.source == 'bl' ? BlSource.streamHeaders : null, tag: _mediaItem(song));
  }

  /// just_audio_background requires a MediaItem tag on every AudioSource — it
  /// is what the notification and lock screen show.
  MediaItem _mediaItem(Song s) {
    final art = artUrl(s.pic, px: 300);
    return MediaItem(
      id: '${s.source}:${s.songmid}',
      title: s.name.isEmpty ? '未知歌曲' : s.name,
      artist: s.singer.isEmpty ? '' : s.singer,
      album: s.albumName,
      duration: (s.interval ?? 0) > 0 ? Duration(seconds: s.interval!) : null,
      artUri: art == null ? null : Uri.parse(art),
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
    _noteHeard(cur, heard: _currentTotal ?? _lastHeard, completed: true);
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
  Duration? get _currentTotal {
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
    final total = _currentTotal;
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
      if (LibraryStore.instance.localFile(s) == null && !AudioPrefetch.instance.has(s, quality)) {
        // 亮屏时只整首备下一首：更靠后的随时会被跳过，白下不如不下。
        // 人已经走了（息屏/切走）就两首都备——后台网络随时会被省电策略掐掉，
        // 磁盘上有货才听得出「还在放歌」。
        final deep = _background ? upcoming.length : 1;
        if (n < deep) {
          unawaited(url(s, quality).then((u) => AudioPrefetch.instance.warm(s, quality, u)).catchError((_) {}));
        }
      }
      unawaited(lyric(s).catchError((_) => LyricResult(lyric: '')));
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
  Future<void> seek(Duration d) async {
    // 拖进度条也是「她听到的位置」：不回写这里，往回拖之后万一断流，重连会把人送
    // 回拖动之前的那一秒，听起来就像歌自己乱跳了一段。
    _lastHeard = d;
    await _ap.seek(d);
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

  Future<void> next() async {
    if (queue.isEmpty) return;
    final i = playMode == PlayMode.random ? _randomNextIndex() : (index + 1) % queue.length;
    await playAt(i);
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
  }

  /// Retry whatever just failed.
  Future<void> retry() => playAt(index);

  Future<void> stopAndClear() async {
    _generation++;
    // 队列清空了，后台那批「找免费版」也就没意义了。
    _vipScanGen++;
    await _ap.stop();
    _netRetry?.cancel();
    _netRetry = null;
    _netRetries = 0;
    _resumeAt = null;
    _resumeKey = null;
    _lastHeard = Duration.zero;
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
    notifyListeners();
  }

  void _onSleepElapsed() {
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepEndsAt = null;
    unawaited(_ap.pause());
    notice = '定时播放已到点，已停止';
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
      await _eq.setEnabled(true);
      final gains = _resampleGains(preset.gains, params.bands.length);
      for (var i = 0; i < params.bands.length; i++) {
        final g = gains[i].clamp(params.minDecibels, params.maxDecibels);
        await params.bands[i].setGain(g);
      }
      eqPresetName = preset.name;
      eqGains = gains;
      AppSettings.instance.setEqPreset(preset.name);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> disableEq() async {
    try {
      await _eq.setEnabled(false);
      eqPresetName = '关闭';
      AppSettings.instance.setEqPreset('关闭');
      notifyListeners();
    } catch (_) {}
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
    _netRetry?.cancel();
    unawaited(_stateSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_ap.dispose());
    super.dispose();
  }
}
