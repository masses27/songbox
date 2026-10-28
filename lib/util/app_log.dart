import 'dart:convert';
import 'dart:io';

import '../settings/app_settings.dart';
import 'app_paths.dart';

/// 听歌日志。
///
/// 她手机上「这首放不出」的时候，我能看到的只有一句人话提示 —— 到底是取链回了空、
/// 换源没换到、还是链接拿到就 403，全都发生在她那边。这一层把过程按步落进本机文件，
/// 设置页一个按钮复制到剪贴板，粘进 POPO 就是证据。
///
/// 只记「哪首歌 / 走到哪一步 / 结果」，不记 cookie、也不记完整播放链接：链接本身就
/// 是一次性的取链凭证，抄进日志再被人看到没有任何好处。
class AppLog {
  /// 一天一个文件，只留最近这么多天：一次闪退顶多要前一天到今天的，再老没人看。
  static const _keepDays = 7;

  /// 日志目录还没就绪（冷启动头几百毫秒）时先攒着，攒够也要能倒出来。
  static const _pendingCap = 200;

  static final List<String> _pending = [];
  static Directory? _dir;

  static Future<void> init() async {
    if (_dir != null) return;
    Directory d;
    try {
      d = await AppPaths.sub('logs');
      _prune(d);
    } catch (_) {
      // 日志起不来不该把冷启动带崩，也不该让后面每一行都去试一遍。
      return;
    }
    _dir = d;
    if (_pending.isNotEmpty) {
      _append(d, _pending);
      _pending.clear();
    }
  }

  /// 记一步。`tag` 是给人扫一眼用的短词（播、链、换、补、试、跳、荐、源、起、卡）。
  static void add(String tag, String message) => write('${_stamp()} [$tag] $message');

  static void write(String line) {
    final d = _dir;
    if (d == null) {
      // 留着最新的：目录一直没就绪时，旧的那几十行反而最没用。
      if (_pending.length >= _pendingCap) _pending.removeAt(0);
      _pending.add(line);
      return;
    }
    _append(d, [line]);
  }

  static void _append(Directory dir, List<String> lines) {
    try {
      File('${dir.path}/${_name(DateTime.now())}')
          .writeAsStringSync('${lines.join('\n')}\n', mode: FileMode.append);
    } catch (_) {
      // 存储被占用、目录被清掉都可能，但日志绝不能把播放带崩。
    }
  }

  /// 栈里只留我们自己那几帧。第 0 帧永远是 dart 核心的抛点（`ListBase.removeWhere`），
  /// 说不出是谁踩的；再往下全是插件和框架。三帧足够指到行，又不至于把日志页挤满。
  static String ownFrames(StackTrace? st) {
    if (st == null) return '';
    return st.toString().split('\n')
        .where((l) => l.contains('package:lyric_music'))
        .take(3)
        .map((l) => l.replaceFirst(RegExp(r'^\s*#\d+\s+'), '').trim())
        .join(' ← ');
  }

  /// 最近这么多行，跨天往前拼。日志文件很小（一天几十行），整读比重排更省事。
  static Future<String> tail({int lines = 400}) async {
    final d = _dir;
    if (d == null) return _pending.join('\n');
    final List<File> files;
    try {
      files = d.listSync().whereType<File>().where(_isLog).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      // 目录被人从外部清掉、存储临时不可用都到这里来：这一页该显示「还没有内容」，
      // 而不是转一辈子圈。
      return '';
    }
    final out = <String>[];
    for (final f in files.reversed) {
      try {
        for (final l in const LineSplitter().convert(f.readAsStringSync()).reversed) {
          if (l.isEmpty) continue;
          out.add(l);
          if (out.length >= lines) break;
        }
      } catch (_) {}
      if (out.length >= lines) break;
    }
    return out.reversed.join('\n');
  }

  /// 复制出去的那一段：先一句版本和音质，后面才是正文。她只要说「日志我发你了」，
  /// 我这边就能对上是哪一版、哪种音质上出的问题。
  static Future<String> exportText() async {
    final n = DateTime.now();
    return '听歌小窝 v${AppSettings.appVersion} · 音质 ${AppSettings.instance.quality} · '
        '${n.month} 月 ${n.day} 日 ${n.hour}:${n.minute.toString().padLeft(2, '0')}\n'
        '----\n${await tail()}';
  }

  static Future<void> clear() async {
    final d = _dir;
    if (d == null) {
      _pending.clear();
      return;
    }
    try {
      for (final f in d.listSync().whereType<File>().where(_isLog)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
    _pending.clear();
    // 清完不再补一行「已清空」：那一行会让这一页永远不为空，界面上「没内容就关掉」
    // 的两个按钮等于没关过，而空着本身就是清过的证据。
  }

  static String _name(DateTime t) =>
      'play-${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}.log';

  static String _stamp() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}:'
        '${n.second.toString().padLeft(2, '0')}';
  }

  static String _base(File f) => f.uri.pathSegments.last;
  static bool _isLog(File f) => _base(f).startsWith('play-') && _base(f).endsWith('.log');

  static void _prune(Directory dir) {
    // 文件名就是日期，字典序等于时间序，所以过期判定只要比一次字符串。
    final keep = _name(DateTime.now().subtract(const Duration(days: _keepDays)));
    for (final f in dir.listSync().whereType<File>().where(_isLog)) {
      if (_base(f).compareTo(keep) < 0) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }
}
