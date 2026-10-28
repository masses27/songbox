import 'dart:convert';
import 'dart:io';

/// 本地 JSON（收藏、最近播放、下载映射、歌单、设置）的读写。
///
/// 这些文件一旦被半写入就会整个丢掉：`writeAsString` 先截断再写，掉电或进程被杀
/// 时留下空文件或截断 JSON，下次启动解析失败只能清零。所以写先进 `.tmp`，再
/// `rename` 顶上（同目录 rename 是原子的），旧文件顺手留成 `.bak`。
/// 读的时候主文件坏了就退到 `.bak`，两边都坏才放弃。
class JsonFile {
  JsonFile._();

  /// 写成功返回 null，失败返回一句原因。
  ///
  /// 原来这里 `catch (_) {}` 一吞到底：磁盘满、目录被外部清掉、存储正被回收，
  /// 调用方拿到的都是「写完了」，于是收藏页面上的心照样变红、脏标记照样清掉，
  /// 下一次启动她发现自己收藏的歌少了一半，而屏幕上从来没有说过为什么。
  /// 现在把失败递出去，让调用方留着「还没落盘」这个状态等下次重试。
  static String? write(File f, Object value) {
    final tmp = File('${f.path}.tmp');
    try {
      tmp.parent.createSync(recursive: true);
      tmp.writeAsStringSync(jsonEncode(value), flush: true);
      if (f.existsSync()) {
        try {
          f.copySync('${f.path}.bak');
        } catch (_) {}
      }
      tmp.renameSync(f.path);
      return null;
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return '$e';
    }
  }

  /// 主文件读不出就试 `.bak`。损坏的主文件改名留档，避免下次启动再撞一次。
  static Object? read(File f, {bool quarantine = true}) {
    for (final path in [f.path, '${f.path}.bak']) {
      final cand = File(path);
      if (!cand.existsSync()) continue;
      try {
        return jsonDecode(cand.readAsStringSync());
      } catch (_) {
        if (path == f.path && quarantine) {
          try {
            cand.renameSync('${f.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}');
          } catch (_) {}
        }
      }
    }
    return null;
  }
}
