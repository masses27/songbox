import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../util/app_log.dart';
import '../util/app_paths.dart';
import '../util/boot_failures.dart';
import '../util/json_file.dart';

/// User preferences that must survive restarts: playback quality and search
/// history. Persisted as one small JSON file next to the library.
class AppSettings extends ChangeNotifier {
  static final AppSettings instance = AppSettings._();
  AppSettings._();

  static const qualities = ['128k', '320k', 'flac'];
  static const themeValues = ['system', 'light', 'dark'];

  /// 和 pubspec.yaml 同步；build.sh 每次打包前按 pubspec 改写这一行，
  /// 「关于」上写错版本号会把她截图里的版本带偏，而排查全靠那句版本。
  /// Windows 那条由 Actions 直接编提交的源码，没人替它改写，所以提交时就得是对的：
  /// version_label_test 与 workflow 的「版本号对齐」步骤一起盯着。
  static const appVersion = '0.8.46';

  String quality = '320k';
  final List<String> searchHistory = [];

  /// Skip on to the next track when one cannot be played (VIP-only, dead source).
  bool autoSkipFailed = true;

  /// 换队列时自动在后台给会员歌找免费版本（从当前这首往后最多 20 首，结果落盘复用）。
  bool vipAutoScan = true;

  /// Ask before starting a download, so a flac on the mobile network is never a
  /// surprise. (Android gives us no reliable Wi-Fi check from Dart, so this is
  /// a plain confirmation rather than an automatic one.)
  bool confirmBeforeDownload = false;

  /// 提前把下一首整首取回本地，切歌就没有那段空白。代价是多耗一首歌的流量，
  /// 所以留了开关——按流量听歌的人可以自己关掉。
  bool preloadNext = true;

  /// 'system' / 'light' / 'dark'。用字符串存，避免这个文件依赖 material。
  String theme = 'system';

  /// 倍速播放，跨启动保持。
  double playbackSpeed = 1.0;

  /// 均衡器预设名，跨启动保持。效果器挂在播放器实例上，重启会丢，
  /// 所以第一首接上播放器后要照这个名字补一次。'关闭' 表示不用均衡器。
  String eqPreset = '关闭';

  /// 循环模式，跨启动保持（'list' / 'single' / 'random' / 'none'）。
  /// 睡前设成单曲循环、第二天重启又变回列表循环，是这一层原来缺的那格。
  String playMode = 'list';

  /// 上次停在下面哪一格（0 首页 / 1 发现 / 2 我的）。
  /// 换主题时整棵主壳要重建（页面的颜色是静态取的），没有这一格就会被抬回首页；
  /// 同一格机制顺带把重启后的落点也记住——她睡前停在「我的」，起来不该从首页重新找。
  int lastTab = 0;

  /// QQ 音乐的设备号：第一次取链时生成，之后一直用这一个。
  /// 所有客户端都报同一个号，正是风控最爱归并的特征。
  String txGuid = '';

  late final File _file;
  bool _loaded = false;

  /// 设置文件到底有没有打开。`_file` 是 `late final`，没赋值就存设置会当场炸，
  /// 而冷启动那一头 `AppPaths.root()` 失败过一次的话（存储正被系统回收），
  /// 原来整个 init 抛出去、外面没人接 —— 应用直接起不来。
  bool _fileOk = false;
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final d = await AppPaths.root();
      _file = File('${d.path}/settings.json');
      _fileOk = true;
    } catch (e) {
      BootFailures.add('设置文件没打开（音质、循环模式这类改动这次存不了）');
      AppLog.add('存', '设置文件没打开：$e');
      return;
    }
    try {
      final j = JsonFile.read(_file);
      if (j is Map) {
        _apply(j);
      }
    } catch (e) {
      BootFailures.add('设置读不出来，已按默认值启动');
      AppLog.add('存', 'settings.json 读失败：$e');
    }
  }

  void _apply(Map<dynamic, dynamic> j) {
    if (j['quality'] is String && qualities.contains(j['quality'])) {
      quality = j['quality'] as String;
    }
    final h = j['searchHistory'];
    if (h is List) searchHistory.addAll(h.whereType<String>());
    autoSkipFailed = j['autoSkipFailed'] != false;
    vipAutoScan = j['vipAutoScan'] != false;
    confirmBeforeDownload = j['confirmBeforeDownload'] == true;
    preloadNext = j['preloadNext'] != false;
    if (j['theme'] is String && themeValues.contains(j['theme'])) theme = j['theme'] as String;
    final sp = (j['playbackSpeed'] as num?)?.toDouble();
    if (sp != null && sp >= 0.5 && sp <= 3) playbackSpeed = sp;
    if (j['eqPreset'] is String) eqPreset = j['eqPreset'] as String;
    if (j['txGuid'] is String) txGuid = j['txGuid'] as String;
    // 循环模式：'list' / 'single' / 'random' / 'none'。写成字符串是为了这个文件
    // 不依赖 material，取值对不对由播放那边按名字认，认不出就回到列表循环。
    if (j['playMode'] is String) playMode = j['playMode'] as String;
    final lt = j['lastTab'] as num?;
    if (lt != null && lt >= 0 && lt < tabCount) lastTab = lt.toInt();
  }

  /// 底部那几格的个数。存的时候按它取范围，界面以后加一格也不用改这一层。
  static const int tabCount = 3;

  void setQuality(String q) {
    if (!qualities.contains(q) || q == quality) return;
    quality = q;
    _save();
  }

  void setAutoSkipFailed(bool v) {
    if (v == autoSkipFailed) return;
    autoSkipFailed = v;
    _save();
  }

  void setVipAutoScan(bool v) {
    if (v == vipAutoScan) return;
    vipAutoScan = v;
    _save();
  }

  void setConfirmBeforeDownload(bool v) {
    if (v == confirmBeforeDownload) return;
    confirmBeforeDownload = v;
    _save();
  }

  void setPreloadNext(bool v) {
    if (v == preloadNext) return;
    preloadNext = v;
    _save();
  }

  void setTheme(String v) {
    if (!themeValues.contains(v) || v == theme) return;
    theme = v;
    _save();
  }

  void setPlaybackSpeed(double v) {
    if (v == playbackSpeed) return;
    playbackSpeed = v;
    _save();
  }

  void setEqPreset(String name) {
    if (name == eqPreset) return;
    eqPreset = name;
    _save();
  }

  void setPlayMode(String v) {
    if (v == playMode) return;
    playMode = v;
    _save();
  }

  void setLastTab(int i) {
    if (i < 0 || i >= tabCount || i == lastTab) return;
    lastTab = i;
    _save();
  }

  /// 取 QQ 设备号，没有就现生成一个存下来。腾讯只要求它是个 10 位数字串。
  ///
  /// 分两段拼，不是随手 `nextInt(9000000000)`：`Random.nextInt` 的上限是 2^32，
  /// 那种写法每次必抛 `RangeError`，而她手机上「检测失败：RangeError (max)…9000000000」
  /// 就是它——取链、榜单、检测三条路都从这一个函数过，所以 QQ 那一层其实一直没真跑通过。
  String ensureTxGuid() {
    if (txGuid.isNotEmpty) return txGuid;
    txGuid = newTxGuid();
    _save();
    return txGuid;
  }

  /// 生成一个 10 位设备号。写成纯函数是为了钉进单测：`Random.nextInt` 的上限是 2^32，
  /// 早先那句 `nextInt(9000000000)` 每次必抛 `RangeError`，而她手机上
  /// 「检测失败：RangeError (max)…9000000000」就是它——取链、榜单、检测三条路都从
  /// 这一个函数过，所以 QQ 那一层其实一直没真跑通过。
  static String newTxGuid([Random? src]) {
    final r = src ?? Random.secure();
    final sb = StringBuffer('${1 + r.nextInt(9)}'); // 首位不为 0，凑够 10 位
    for (var i = 0; i < 9; i++) {
      sb.write(r.nextInt(10));
    }
    return sb.toString();
  }

  void rememberSearch(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    searchHistory.remove(kw);
    searchHistory.insert(0, kw);
    while (searchHistory.length > 20) {
      searchHistory.removeLast();
    }
    _save();
  }

  void forgetSearch(String keyword) {
    if (searchHistory.remove(keyword)) _save();
  }

  /// 撤销一次「删掉一个历史词」：放回她原来那个位置。
  /// 只删一个词是常事，而攒这些词靠的是她一次次搜出来的，不该一没留神就没了。
  void restoreSearch(String keyword, int index) {
    if (keyword.isEmpty || searchHistory.contains(keyword)) return;
    searchHistory.insert(index.clamp(0, searchHistory.length), keyword);
    _save();
  }

  void clearSearchHistory() {
    if (searchHistory.isEmpty) return;
    searchHistory.clear();
    _save();
  }

  /// 撤销一次「清空历史」：把刚才那批词原样放回去。
  void restoreSearchHistory(List<String> words) {
    if (words.isEmpty) return;
    searchHistory
      ..clear()
      ..addAll(words.take(20));
    _save();
  }

  bool _saveFailed = false;

  void _save() {
    notifyListeners();
    if (!_fileOk) return;
    final err = JsonFile.write(_file, {
      'quality': quality,
      'searchHistory': searchHistory,
      'autoSkipFailed': autoSkipFailed,
      'vipAutoScan': vipAutoScan,
      'confirmBeforeDownload': confirmBeforeDownload,
      'preloadNext': preloadNext,
      'theme': theme,
      'playbackSpeed': playbackSpeed,
      'eqPreset': eqPreset,
      'playMode': playMode,
      'lastTab': lastTab,
      'txGuid': txGuid,
    });
    // 每次改设置都是整份重写，所以这里不用自己排重试：下一次改动就是把这一次
    // 补回去的那一趟。但第一次失败必须留一行日志，不然「设了没存住」这件事
    // 从头到尾只有她一个人知道。
    if (err != null && !_saveFailed) {
      _saveFailed = true;
      AppLog.add('存', '设置没写进磁盘，之后的改动会接着重试：$err');
    } else if (err == null && _saveFailed) {
      _saveFailed = false;
      AppLog.add('存', '设置重新存好了');
    }
  }
}
