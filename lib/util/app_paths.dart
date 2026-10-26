import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 所有要落到磁盘上的东西（设置、歌单、音源脚本、日志、封面、预取、下载）都从这里拿根目录。
///
/// 收口之前是七个文件各自调 path_provider，桌面版露出两个毛病：
///
/// 1. Windows 上 `getApplicationDocumentsDirectory()` 返回的就是用户的「文档」根目录
///    （`path_provider_windows` 直接给 `WindowsKnownFolder.Documents`，不像支持目录那样
///    带 `Company\Product` 后缀）。设置、歌单、日志、音源就这么撒进她的文档里，想拷走
///    还不知道该带哪几个文件夹。
/// 2. `getExternalStorageDirectory()` 在 Windows 上根本不实现，是**抛** `UnimplementedError`
///    而不是返回 null —— 所以封面、预取、下载那三处 `ext ?? docs` 的兜底在桌面上压根走不到，
///    整个功能当场失败。
///
/// 安卓那条路一个字没改：那里 docs 与 external 本就是同一个应用私有目录
/// （`/storage/emulated/0/Android/data/<包名>/files`），换到这一层之后落点不变。
class AppPaths {
  AppPaths._();

  static Directory? _root;

  /// 数据根目录。桌面版是包自己旁边的 `data/`（拷到哪儿数据跟到哪儿，也不往「文档」里撒）；
  /// 旁边写不动（比如装在只读位置）退回应用支持目录；其余平台维持原样。
  static Future<Directory> root() async {
    final r = _root;
    if (r != null) return r;
    if (Platform.isWindows) {
      final side = await _desktopRoot();
      _root = side;
      return side;
    }
    final d = await getApplicationDocumentsDirectory();
    _root = d;
    return d;
  }

  /// root 下面一个固定名字的子目录，不存在就建出来（调用方要能容忍建不出来）。
  static Future<Directory> sub(String name) async {
    final r = await root();
    final out = Directory('${r.path}/$name');
    if (!out.existsSync()) out.createSync(recursive: true);
    return out;
  }

  /// 包旁边那个 `data/`，探一次写不写得动；写不动就换 `%APPDATA%`。
  static Future<Directory> _desktopRoot() async {
    final beside = Directory('${File(Platform.resolvedExecutable).parent.path}/data');
    try {
      if (!beside.existsSync()) beside.createSync(recursive: true);
      // 光 createSync 不够：有的位置能建目录却不让写文件，那就当场试一发真的写。
      final probe = File('${beside.path}/.write');
      await probe.writeAsString('ok');
      await probe.delete();
      return beside;
    } catch (_) {
      // 日志起不来不该把冷启动带崩，下载和封面那边也一样，所以这里只往回退一步。
      try {
        return await getApplicationSupportDirectory();
      } catch (_) {
        return beside;
      }
    }
  }
}
