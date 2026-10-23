import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
  static const appVersion = '0.8.33';

  String quality = '320k';
  final List<String> searchHistory = [];

  /// Skip on to the next track when one cannot be played (VIP-only, dead source).
  bool autoSkipFailed = true;

  /// 换队列时自动在后台给会员歌找免费版本（一次最多十几首，结果落盘复用）。
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
  /// 所以第一首接上音源后要照这个名字补一次。'关闭' 表示不用均衡器。
  String eqPreset = '关闭';

  /// QQ 音乐的设备号：第一次取链时生成，之后一直用这一个。
  /// 所有客户端都报同一个号，正是风控最爱归并的特征。
  String txGuid = '';

  late final File _file;
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final d = await getApplicationDocumentsDirectory();
    _file = File('${d.path}/settings.json');
    final j = JsonFile.read(_file);
    if (j is Map) {
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
    }
  }

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

  void _save() {
    notifyListeners();
    JsonFile.write(_file, {
      'quality': quality,
      'searchHistory': searchHistory,
      'autoSkipFailed': autoSkipFailed,
      'vipAutoScan': vipAutoScan,
      'confirmBeforeDownload': confirmBeforeDownload,
      'preloadNext': preloadNext,
      'theme': theme,
      'playbackSpeed': playbackSpeed,
      'eqPreset': eqPreset,
      'txGuid': txGuid,
    });
  }
}
