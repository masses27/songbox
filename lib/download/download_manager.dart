import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../library/library_store.dart';
import '../models/song.dart';
import '../music_sdk/bl_source.dart';
import '../settings/app_settings.dart';
import '../ui/pages/builtin_library.dart';
import '../util/app_paths.dart';
import '../util/humanize.dart';

/// Downloads a resolved song URL to the app's external files/Music directory.
///
/// Uses app-private external storage (Android 10+ scoped storage — no
/// runtime permission needed). Files remain visible under
/// `Android/data/<appId>/files/Music/`.
class DownloadManager extends ChangeNotifier {
  static final DownloadManager instance = DownloadManager._();
  DownloadManager._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    // 只管到「响应头回来」那一下：dio 的 receiveTimeout 是套在 request.close() 上的
    // （dio 5.11 的 io_adapter.dart:162），字节流开始往这边吐之后它一概不管。
    // 半途断流靠下面 [_stallTimeout] 那一层；这一行只管「请求发出去了、响应头迟迟
    // 不回来」那一段，给到 5 分钟不误伤慢站。
    receiveTimeout: const Duration(minutes: 5),
    responseType: ResponseType.stream,
  ));

  /// 连续这么多秒没收到一个新块，就当这条连接已经死了。
  ///
  /// 少了这一层，CDN 半路不回话时 `await for` 永远挂着：任务停在 running、进度条
  /// 冻在当前这一格，界面上既没有失败也没有完成 —— 她只能把应用整个关掉。
  static const _stallTimeout = Duration(seconds: 30);

  final Map<String, DownloadTask> _tasks = {};
  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);

  /// 开始下载。已经在下的那一首不会重复排队——返回 false，调用方就不该说「已开始下载」。
  Future<bool> enqueue(Song song, [String? quality]) async {
    final id = '${song.source}:${song.songmid}';
    if (_tasks[id]?.running ?? false) return false;
    final task = DownloadTask(id: id, song: song, quality: quality ?? AppSettings.instance.quality);
    _tasks[id] = task;
    notifyListeners();
    unawaited(_run(task));
    return true;
  }

  Future<void> _run(DownloadTask task) async {
    IOSink? sink;
    try {
      final url = await BuiltinLibrary.instance
          .resolveUrl(task.song, task.quality)
          .timeout(const Duration(seconds: 30));
      final dir = await musicDir();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final safeName = _sanitize('${task.song.singer} - ${task.song.name}');
      final ext = _guessExtension(url);
      // 名字里带上来源、歌曲 id 和音质：翻唱同名曲不会互相覆盖，重下也会
      // 落在同一个文件上（先截断再写），LibraryStore 的映射对得上。
      final file = File(
          '${dir.path}/${safeName}_${task.song.source}-${task.song.songmid}_${task.quality}.$ext');
      task.targetFile = file.path;
      sink = file.openWrite();
      var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
      final resp = await _dio.get<ResponseBody>(url,
          options: Options(
            responseType: ResponseType.stream,
            // 防盗链头按地址判（和播放、预取同一条件）：下载会员墙后面的歌时，
            // 拿到的链接属于 B 站，任务里那首歌却还写着网易云。
            headers: BlSource.headersFor(url),
          ),
          cancelToken: task.token,
          onReceiveProgress: (r, t) {
            task.received = r;
            task.total = t;
            // 每个 chunk 都 notify 的话，列表页每秒重绘几十次，进度条也抖。
            final now = DateTime.now();
            if (now.difference(lastNotify).inMilliseconds >= 200) {
              lastNotify = now;
              notifyListeners();
            }
          });
      // `data!` 在流式响应里不是 guaranteed 非空：预取那一路按 null 收的，这里同样
      // 得收住 —— 空一下是 `Null check operator` 那句天书，而不是「没取到数据」。
      final body = resp.data;
      if (body == null) {
        task.error = '没取到数据，换一个音质或稍后再试';
        return;
      }
      await for (final chunk in body.stream.timeout(_stallTimeout)) {
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      // 磁盘满或连接被掐断时字节数对不上，不能当成下载成功。
      final written = file.lengthSync();
      if (task.total > 0 && written != task.total) {
        try {
          file.deleteSync();
        } catch (_) {}
        task.error = written == 0 ? '没取到数据，换一个音质或稍后再试' : '下载不完整，请重试';
        return;
      }
      task.done = true;
      LibraryStore.instance.recordLocalPath(task.song, file.path);
    } on TimeoutException {
      // 两处 30 秒抛的是同一种异常，可卡在哪儿得说哪句话：`resolveUrl` 那一段是
      // 还没开始下，字节流那一段才是下到一半没回来。进度条别再冻在当前那一格。
      task.error = task.targetFile == null
          ? '问那个平台要地址要了半天没回话，重试会再问一次'
          : '下到一半没动静了，重试会从头重下这一首';
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // A cancelled partial file is useless — drop it.
        try {
          if (task.targetFile != null) await File(task.targetFile!).delete();
        } catch (_) {}
      } else {
        task.error = humanizeError(e);
      }
    } on FileSystemException {
      task.error = '这台机器存储空间不足，清理后再下载';
    } catch (e) {
      task.error = humanizeError(e);
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      task.running = false;
      notifyListeners();
    }
  }

  /// Re-run a failed download from scratch.
  Future<void> retry(DownloadTask task) async {
    _tasks.remove(task.id);
    notifyListeners();
    await enqueue(task.song, task.quality);
  }

  /// Stop an in-flight download (deleting its partial file) or take a
  /// finished-but-failed task off the list.
  void cancel(DownloadTask task) {
    if (task.running) task.token.cancel('用户取消');
    _tasks.remove(task.id);
    notifyListeners();
  }

  /// Removes a single downloaded song (record + file).
  ///
  /// 返回 false 表示文件没删掉（正被播放器占着）。这时候记录必须留着：
  /// 把那一行删了，歌还在磁盘上占着位置，却再也没有一个列表认它。
  Future<bool> deleteDownload(Song song) async {
    final path = LibraryStore.instance.localFile(song);
    if (path != null) {
      final f = File(path);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {
          return false;
        }
      }
    }
    LibraryStore.instance.remove(LibraryKind.downloaded, song);
    _tasks.remove('${song.source}:${song.songmid}');
    notifyListeners();
    return true;
  }

  /// Bulk delete used by the settings page; returns how many **bytes** went away.
  ///
  /// 按磁盘删，不按清单删。清单是那份 `downloads_paths.json`，它少几行太常见了：
  /// 一次写盘失败、旧版本「全部删除」把它整罐清空过一次、换机时只带走了歌没带走记录。
  /// 那几首的文件还原样占着她手机的存储，界面上却一首都不认——以前这里照着清单循环，
  /// 于是「全部删除」删完还剩一半，而提示条照报删除前的总占用，说成一个没发生的数。
  Future<int> deleteAllDownloads() async {
    // 先把还在下的取消掉：不取消的话，这一轮清空跑完它们还在往文件里写，
    // 写完又把路径记回库里——界面上就是「明明清了，过一会儿又冒出一首」。
    for (final t in _tasks.values) {
      if (t.running) t.token.cancel('清空下载');
    }
    var bytes = 0;
    final deleted = <String>{};
    final dir = await musicDir();
    if (dir.existsSync()) {
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final size = _size(e);
        try {
          e.deleteSync();
          bytes += size;
          deleted.add(e.path);
        } catch (_) {}
      }
    }
    // 清单里指向别处的（早期版本存过外部存储的公共目录），照着路径再补一轮。
    for (final song in LibraryStore.instance.list(LibraryKind.downloaded)) {
      final path = LibraryStore.instance.localFile(song);
      if (path == null || deleted.contains(path)) continue;
      final f = File(path);
      final size = _size(f);
      try {
        f.deleteSync();
        bytes += size;
      } catch (_) {}
    }
    _tasks.clear();
    LibraryStore.instance.replaceDownloaded(const []);
    notifyListeners();
    return bytes;
  }

  static int _size(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Frees the image/HTTP cache. Only the cache *contents* are removed, since
  /// the directories themselves are expected to exist by the engine.
  static Future<int> deleteImageCache() async {
    var bytes = 0;
    for (final dir in await _cacheDirs()) {
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        try {
          if (e is File) {
            bytes += e.lengthSync();
            await e.delete();
          } else if (e is Directory) {
            await e.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
    return bytes;
  }

  /// 只量不删，给「清除缓存」那句确认用。
  ///
  /// 原来弹窗上的数字是 `deleteImageCache()` 顺手报回来的 —— 也就是说她还没按
  /// 「只清缓存」，缓存就已经没了，那句确认从一开始就没得选。
  static Future<int> imageCacheBytes() async {
    var bytes = 0;
    for (final dir in await _cacheDirs()) {
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        try {
          bytes += e.lengthSync();
        } catch (_) {}
      }
    }
    return bytes;
  }

  static Future<List<Directory>> _cacheDirs() async {
    final out = <Directory>[Directory.systemTemp];
    try {
      out.add(Directory('${(await AppPaths.root()).path}/cachefile'));
    } catch (_) {}
    return out;
  }

  /// App-private Music folder (Android 10+ scoped storage friendly).
  /// 桌面版落在包旁边的 `data/Music`。这里只算路径不建目录：查个占用也要建文件夹就多余了。
  static Future<Directory> musicDir() async => Directory('${(await AppPaths.root()).path}/Music');

  static Future<int> musicDirBytes() async {
    final dir = await musicDir();
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final e in dir.listSync()) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }

  static String _sanitize(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static String _guessExtension(String url) {
    final m =
        RegExp(r'\.(mp3|flac|m4a|m4s|aac|ogg|wav|wma)(\?|$)', caseSensitive: false).firstMatch(url);
    final e = m?.group(1)?.toLowerCase() ?? 'mp3';
    // B 站的音轨后缀写成 `.m4s`（分片 MP4 里装 AAC），落到磁盘按 `.m4a` 存。
    return e == 'm4s' ? 'm4a' : e;
  }
}

class DownloadTask {
  final String id;
  final Song song;
  final String quality;
  bool running = true;
  bool done = false;
  int received = 0;
  int total = -1;
  String? error;
  String? targetFile;
  final CancelToken token = CancelToken();
  DownloadTask({required this.id, required this.song, required this.quality});

  double? get progress => total > 0 ? received / total : null;
}
