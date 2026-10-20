import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../library/library_store.dart';
import '../models/song.dart';
import '../music_sdk/bl_source.dart';
import '../settings/app_settings.dart';
import '../ui/pages/builtin_library.dart';
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
    receiveTimeout: const Duration(minutes: 5),
    responseType: ResponseType.stream,
  ));

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
            // B 站的音频直链要带 Referer，不带实测就 403（和播放、预取同一条件）。
            headers: task.song.source == 'bl' ? BlSource.streamHeaders : null,
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
      await for (final chunk in resp.data!.stream) {
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
      task.error = '手机存储空间不足，清理后再下载';
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
  Future<void> deleteDownload(Song song) async {
    final path = LibraryStore.instance.localFile(song);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    LibraryStore.instance.remove(LibraryKind.downloaded, song);
    _tasks.remove('${song.source}:${song.songmid}');
    notifyListeners();
  }

  /// Bulk delete used by the settings page; returns how many files went away.
  Future<int> deleteAllDownloads() async {
    var n = 0;
    for (final song in LibraryStore.instance.list(LibraryKind.downloaded)) {
      final path = LibraryStore.instance.localFile(song);
      if (path == null) continue;
      try {
        await File(path).delete();
        n++;
      } catch (_) {}
    }
    _tasks.clear();
    LibraryStore.instance.replaceDownloaded(const []);
    notifyListeners();
    return n;
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

  static Future<List<Directory>> _cacheDirs() async {
    final out = <Directory>[Directory.systemTemp];
    try {
      final d = await getApplicationDocumentsDirectory();
      out.add(Directory('${d.path}/cachefile'));
    } catch (_) {}
    return out;
  }

  /// App-private Music folder (Android 10+ scoped storage friendly).
  static Future<Directory> musicDir() async {
    final extDir = await getExternalStorageDirectory();
    return Directory('${(extDir ?? await getApplicationDocumentsDirectory()).path}/Music');
  }

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
