import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/song.dart';
import '../music_sdk/bl_source.dart';
import '../settings/app_settings.dart';
import '../util/app_paths.dart';

/// 提前把下一首整首下到应用私有目录，切过去那一刻直接读本地文件。
///
/// 链接本身早就预热过了，但真正出声之前还要建一次 HTTP 连接、等播放器缓冲够，
/// 那段时间屏幕上只有进度条空转——听着就是「切歌卡好几秒」。整首落到磁盘上，
/// 这一跳和放本地下载过的歌一样快。
///
/// 只给「下一首」下：更靠后的随时可能被跳过，白下更费流量。
class AudioPrefetch {
  static final AudioPrefetch instance = AudioPrefetch._();
  AudioPrefetch._();

  /// 目录总量上限。按 320k 一首四五兆算，够攒十几首。
  static const maxTotalBytes = 60 << 20;

  /// 单首超过这个大小就不预取了（无损整轨），正常在线播就行。
  static const maxOneFileBytes = 30 << 20;

  static const _partSuffix = '.part';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    // 这一项只管到「响应头回来」那一刻：dio 的 receiveTimeout 是套在 request.close()
    // 上的（dio 5.11 的 io_adapter.dart:162），字节流开始往这边吐之后它就不管了。
    // 半途断流真正靠的是下面 [_stallTimeout] 那一层，别把这行当成总闸。
    receiveTimeout: const Duration(seconds: 45),
    responseType: ResponseType.stream,
  ));

  /// 字节流连续这么多秒不给一个新块就按「这条连接已经死了」收摊。
  /// 少了这一层，CDN 半路不回话时 `await for` 永远挂着：预取那个坑位（[_running]）
  /// 从此占着，这一首再也预取不上，磁盘上还留着写了一半的 .part。
  static const _stallTimeout = Duration(seconds: 30);

  /// 已完成下载 键 -> 文件路径。目录里现成的文件在第一次用到时扫进来。
  final Map<String, String> _done = {};

  /// 正在下载的键 -> 取消令牌，同一个键不会下两遍。
  final Map<String, CancelToken> _running = {};

  Directory? _dir;
  Future<void>? _scan;

  /// 键里那一档写的是「实际能拿到的」，不是设置里想要的那一档。
  ///
  /// B 站整首只有 192k、QQ 和酷狗匿名只有 128k：按设置值命名的话，同一份字节会在
  /// `flac` 和 `320k` 两个键下各存一遍，她改一次音质设置就白下一首。
  /// `servedBy` 是这条音频真正来自的平台（换源记住的那个版本），没说就按队列里
  /// 那个 source 算。
  static String key(Song song, String quality, {String? servedBy}) =>
      'pf-${song.source}-${song.songmid}-${heardQuality(quality, servedBy ?? song.source)}';

  /// 已经下好的完整文件；没有返回 null。
  Future<String?> path(Song song, String quality, {String? servedBy}) async {
    final k = key(song, quality, servedBy: servedBy);
    final hit = _done[k];
    if (hit != null) return hit;
    await _prime();
    return _done[k];
  }

  /// 开机时跑一次：把磁盘上留下的旧文件扫进内存表，顺带建好目录。
  /// 不这么做的话，第一次切歌要在播放那一跳里等完这趟磁盘往返。
  Future<void> prime() => _prime();

  /// 建目录或 `list()` 本身可能抛（外部存储没挂载、权限正被系统回收）。存下来的
  /// 那个 Future 一旦是失败的，后面每次 await 都当场炸——播放路径等于永久读不到
  /// 本地已经下好的整首。失败就把它清掉，下次重新扫一遍。
  Future<void> _prime() async {
    final scan = _scan ??= _rescan();
    try {
      await scan;
    } catch (_) {
      if (identical(_scan, scan)) _scan = null;
    }
  }

  /// 内存表里已经有整首了？批量预取用这个问，别为每首歌都 await 一次磁盘扫描。
  bool has(Song song, String quality, {String? servedBy}) =>
      _done.containsKey(key(song, quality, servedBy: servedBy));

  /// 拿到链接后开始后台下载。已在下、已下好、或设置里关了预取就直接返回。
  void warm(Song song, String quality, String url, {String? servedBy}) {
    if (url.isEmpty || !AppSettings.instance.preloadNext) return;
    final k = key(song, quality, servedBy: servedBy);
    if (_done.containsKey(k) || _running.containsKey(k)) return;
    final token = CancelToken();
    _running[k] = token;
    // 防盗链头按地址判：换源给的是 B 站的音轨，而这一首在队列里仍是网易云那首。
    unawaited(_download(k, url, token, BlSource.headersFor(url))
        .whenComplete(() => _running.remove(k)));
  }

  /// 这一首放着放着失败了：本地那份可能是半截坏文件，扔掉让下次重新取。
  /// 整首按前缀扔，不猜档位——换源关系往往就在这一步被清掉，档位跟着变，
  /// 只删「设置里那一档」的话 B 站那份 192k 会留在磁盘上被接着放。
  void drop(Song song) {
    final prefix = 'pf-${song.source}-${song.songmid}-';
    for (final k in _done.keys.where((k) => k.startsWith(prefix)).toList()) {
      final p = _done.remove(k);
      if (p != null) _deleteLater(File(p));
    }
    for (final k in _running.keys.where((k) => k.startsWith(prefix)).toList()) {
      _running.remove(k)?.cancel('这一首要重取');
    }
  }

  /// 队列清空了，还在下的那几首没有意义了。
  void cancelRunning() {
    for (final t in _running.values) {
      t.cancel('队列已清空');
    }
    _running.clear();
  }

  /// 「清除缓存」用。
  Future<int> clearAll() async {
    cancelRunning();
    var bytes = 0;
    final dir = _dir;
    _done.clear();
    if (dir == null || !dir.existsSync()) return bytes;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      try {
        bytes += await e.length();
        await e.delete();
      } catch (_) {}
    }
    return bytes;
  }

  /// 只量不删：先让她看清要清掉多少，再决定清不清。
  Future<int> pendingBytes() async {
    final dir = await _dirOf();
    if (!dir.existsSync()) return 0;
    var bytes = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      try {
        bytes += await e.length();
      } catch (_) {}
    }
    return bytes;
  }

  Future<Directory> _dirOf() async {
    final d = _dir;
    if (d != null) return d;
    // 和下载目录同一处：安卓是应用私有目录（不进系统备份，也不挤内部存储），桌面版是包旁边的 data/。
    final out = await AppPaths.sub('prefetch');
    _dir = out;
    return out;
  }

  /// 重启后磁盘上还留着上次下的文件，但内存表是空的；不扫一遍的话，
  /// 同一首会白下一遍，而且旧文件永远等不到淘汰。
  ///
  /// 全程走异步文件接口：这一轮要是落在切歌那一刻，listSync 加逐个 statSync
  /// 会冻住主 isolate，屏幕上就是「点下一首卡一下」。所以开机先 [prime] 一遍。
  Future<void> _rescan() async {
    final dir = await _dirOf();
    final cutoff = DateTime.now().subtract(const Duration(hours: 2));
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      try {
        if (name.endsWith(_partSuffix)) {
          // 半截文件用不上；上次崩掉留下的，顺手清掉。
          if ((await e.stat()).modified.isBefore(cutoff)) await e.delete();
          continue;
        }
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        _done[name.substring(0, dot)] = e.path;
      } catch (_) {}
    }
  }

  Future<void> _download(String k, String url, CancelToken token, [Map<String, String>? headers]) async {
    final dir = await _dirOf();
    final part = File('${dir.path}/$k$_partSuffix');
    try {
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream, headers: headers),
        cancelToken: token,
      );
      final body = resp.data;
      if (body == null) return;
      final sink = part.openWrite();
      var written = 0;
      var giveUp = false;
      try {
        await for (final chunk in body.stream.timeout(_stallTimeout)) {
          written += chunk.length;
          // 超大文件不值得为「可能用一次」先下满，剩下的交给在线播。
          if (written > maxOneFileBytes) {
            giveUp = true;
            break;
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (giveUp) {
        _deleteLater(part);
        return;
      }
      final total = int.tryParse(resp.headers.value(Headers.contentLengthHeader) ?? '') ?? -1;
      // 中途断流的话只有半截，当成完整文件放会在半首处停住。
      if (total > 0 && written != total) {
        _deleteLater(part);
        return;
      }
      final finalFile = File('${dir.path}/$k.${_ext(url)}');
      try {
        if (finalFile.existsSync()) finalFile.deleteSync();
      } catch (_) {}
      _done[k] = part.renameSync(finalFile.path).path;
      await _evict(dir);
    } catch (_) {
      // 预取失败什么都不做：真轮到它播放时还有一条完整重试的路。
      _deleteLater(part);
    }
  }

  /// 超出上限就按最后修改时间从旧的开始删，正在写的那半截不算。
  Future<void> _evict(Directory dir) async {
    final entries = <({File file, DateTime at, int bytes})>[];
    await for (final e in dir.list()) {
      if (e is! File || e.path.endsWith(_partSuffix)) continue;
      try {
        final stat = await e.stat();
        entries.add((file: e, at: stat.modified, bytes: stat.size));
      } catch (_) {}
    }
    entries.sort((a, b) => a.at.compareTo(b.at));
    var total = entries.fold<int>(0, (s, e) => s + e.bytes);
    for (final e in entries) {
      if (total <= maxTotalBytes) break;
      total -= e.bytes;
      _done.removeWhere((_, v) => v == e.file.path);
      _deleteLater(e.file);
    }
  }

  void _deleteLater(File f) {
    unawaited(f.delete().catchError((_) => f));
  }

  static String _ext(String url) {
    final m =
        RegExp(r'\.(mp3|flac|m4a|m4s|aac|ogg|wav|wma)(\?|$)', caseSensitive: false).firstMatch(url);
    final e = m?.group(1)?.toLowerCase() ?? 'mp3';
    // B 站的音轨后缀写成 `.m4s`（分片 MP4 里装 AAC），落到磁盘按 `.m4a` 存。
    return e == 'm4s' ? 'm4a' : e;
  }
}
