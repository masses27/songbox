/// 网易云封面地址的统一改写；顺带给播放卡准备本地封面文件。
///
/// 接口给的是 `http://p1.music.126.net/xxx.jpg?imageView=1&thumbnail=800y800…`
/// 这一长串它自家的缩放/水印指令（多条用 `%7C` 拼起来）。手机上这一串经常整条
/// 取不到图——列表里就只剩占位渐变；偶尔取到了也是 600KB～1MB 的原图。
/// 换成 `https://` + `?param=NNNyNNN` 是同一张图，实测 300 方的约 130KB。
///
/// 尺寸只落到几档固定值：同一屏的请求命中同一份缓存，翻页面时不用再下一遍。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'app_paths.dart';

const _steps = [120, 200, 300, 400, 600];

/// 图片请求要带的头。
///
/// 网易云的封面 CDN 认 UA：dart:io 的默认值（`Dart/3.x (dart:io)`）一律 403，
/// 换成浏览器 UA 就是 200 —— 而 `HttpClient.defaultUserAgent` 没有 setter，
/// 只能每个请求自己带。Referer 反而不是必须的（不带也 200），留着当保险。
const artHeaders = {
  'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Referer': 'https://music.163.com/',
};

/// [px] 是这块位置大概需要多少物理像素（逻辑边长 × devicePixelRatio）。
String? artUrl(String? raw, {int px = 300}) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s);
  final host = uri?.host ?? '';
  if (uri == null || uri.path.isEmpty) return s;
  if (uri.scheme != 'http' && uri.scheme != 'https') return s;
  if (!host.endsWith('music.126.net') && !host.endsWith('music.163.com')) return s;
  final size = _steps.firstWhere((e) => e >= px, orElse: () => _steps.last);
  // 路径里带 == 和 +，是签名的一部分，只能按原样截断，不能过一遍 Uri.path 的解码。
  final cut = s.indexOf('?');
  final clean = (cut < 0 ? s : s.substring(0, cut)).replaceFirst('http://', 'https://');
  return '$clean?param=${size}y$size';
}

/// 播放卡上的封面：得先把图落到本地，返回本地文件路径（失败返回 null）。
///
/// audio_service 拿到 artUri 之后**不发请求**，直接把它当文件读
/// （AudioService.java:217 `BitmapFactory.decodeFile(artUri.getPath())`）。
/// 给它 `https://p1.music.126.net/x.jpg?param=300y300`，它取到的路径是
/// `/x.jpg?param=…` 那截，解不出位图，卡上永远只剩系统默认的占位音符。
/// 它自己那套加载也不带 UA，网易云 CDN 对裸 UA 一律 403——两头都通不了，
/// 只能我们下一遍存本地，再把 `file://` 交给卡。
///
/// 一张约 130KB，目录里最多留 24 张（约 3MB）；被淘汰的下次会重新下，
/// 所以内存里不做表，每次就看文件在不在。
Future<String?> artFileFor(String? url) async {
  final s = url?.trim() ?? '';
  if (s.isEmpty || !s.startsWith('http')) return null;
  try {
    final dir = await _artDirOf();
    final f = File('${dir.path}/${md5.convert(utf8.encode(s))}.jpg');
    if (await f.exists() && await f.length() >= 512) return f.path;
    final r = await _artDio.get<List<int>>(
      s,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = r.data;
    if (bytes == null || bytes.length < 512) return null;
    await f.writeAsBytes(bytes, flush: true);
    unawaited(_pruneArt(dir));
    return f.path;
  } catch (_) {
    // 封面取不到不该影响放歌，卡上继续用占位图。
    return null;
  }
}

final _artDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 12),
    headers: artHeaders,
  ),
);

Directory? _artDir;

Future<Directory> _artDirOf() async {
  final d = _artDir;
  if (d != null) return d;
  // 和预取目录同一处：安卓是应用私有目录（不进系统备份，也不挤内部存储），桌面版是包旁边的 data/。
  final out = await AppPaths.sub('covers');
  _artDir = out;
  return out;
}

Future<void> _pruneArt(Directory dir) async {
  try {
    final all = <({File file, DateTime at})>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      all.add((file: e, at: (await e.stat()).modified));
    }
    if (all.length <= _artKeep) return;
    all.sort((a, b) => a.at.compareTo(b.at));
    for (final e in all.take(all.length - _artKeep)) {
      try {
        await e.file.delete();
      } catch (_) {}
    }
  } catch (_) {}
}

const _artKeep = 24;
