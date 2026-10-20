import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../engine/lx_engine.dart';
import '../library/library_store.dart';
import '../util/json_file.dart';

class SourceMeta {
  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;
  String? fileName;
  bool enabled;
  String? bundleKey;
  int lastUpdatedAt;

  SourceMeta({
    required this.id,
    required this.name,
    this.description = '',
    this.version = '',
    this.author = '',
    this.homepage = '',
    this.fileName,
    this.enabled = false,
    this.bundleKey,
    this.lastUpdatedAt = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'version': version,
        'author': author,
        'homepage': homepage,
        'fileName': fileName,
        'enabled': enabled,
        'bundleKey': bundleKey,
        'lastUpdatedAt': lastUpdatedAt,
      };

  factory SourceMeta.fromJson(Map<String, dynamic> j) => SourceMeta(
        id: j['id'],
        name: j['name'] ?? j['id'],
        description: j['description'] ?? '',
        version: j['version'] ?? '',
        author: j['author'] ?? '',
        homepage: j['homepage'] ?? '',
        fileName: j['fileName'],
        enabled: j['enabled'] == true,
        bundleKey: j['bundleKey'],
        lastUpdatedAt: (j['lastUpdatedAt'] as num?)?.toInt() ?? 0,
      );


  /// parse the standard lx header comment block:
  /*!
   * @name xxx
   * @description ...
   * @version v1.0.0
   * @author ...
   * @homepage ...
   */
  static Map<String, String> parseMeta(String script) {
    final result = <String, String>{'name': '', 'description': '', 'version': '', 'author': '', 'homepage': ''};
    String content = script;
    final marker = content.indexOf('\n*/');
    if (content.trimLeft().startsWith('/*') && marker > 0) {
      content = content.substring(0, marker);
    }
    for (final line in content.split('\n')) {
      final m = RegExp(r'@(\w+)\s+(.*)').firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.trim();
      final value = m.group(2)!.trim();
      if (key == 'name' && value.isNotEmpty && !value.contains('声明')) result['name'] = value;
      if (key == 'description') result['description'] = value;
      if (key == 'version') result['version'] = value;
      if (key == 'author') result['author'] = value;
      if (key == 'homepage') result['homepage'] = value;
    }
    return result;
  }
}

class SourceManager {
  static final SourceManager instance = SourceManager._();
  final List<SourceMeta> list = [];
  String? activeSourceId;
  late Directory _dir;
  File get _indexFile => File('${_dir.path}/sources.json');

  /// Bundled sources shipped in `assets/js/sources/<key>.js`.
  /// They can be updated in-place via [refreshBundled].
  static const List<String> bundledSourceKeys = [
    'sixyin',   // 六音（曲库最全，但初始化依赖网络握手，慢）
    'lx',       // 独家
    'huibq',    // Huibq（走 kw，简单稳定）
    'flower',   // 野花
    'grass',    // 野草
    'changqing',// 长青 SVIP
    'huanyin',  // 幻音
    'ikun',     // ikun
  ];

  /// Mirrors tried in order when refreshing a bundled source.
  static const List<String> _updateMirrors = [
    'https://cdn.jsdelivr.net/gh/pdone/lx-music-source@main/{key}/latest.js',
    'https://raw.githubusercontent.com/pdone/lx-music-source/main/{key}/latest.js',
    'https://ghproxy.net/https://raw.githubusercontent.com/pdone/lx-music-source/main/{key}/latest.js',
    'https://gh.llkk.cc/https://raw.githubusercontent.com/pdone/lx-music-source/main/{key}/latest.js',
  ];

  SourceManager._();

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory('${docs.path}/sources');
    if (!await _dir.exists()) await _dir.create(recursive: true);
    if (_indexFile.existsSync()) {
      final arr = JsonFile.read(_indexFile);
      if (arr is List) {
        list.clear();
        list.addAll(arr.map((e) => SourceMeta.fromJson(Map<String, dynamic>.from(e))));
        activeSourceId = list.firstWhere((s) => s.enabled, orElse: () => SourceMeta(id: '', name: '')).id;
        if (activeSourceId?.isEmpty ?? true) activeSourceId = null;
      }
    }
    if (list.isEmpty) {
      await _seedBundledSources();
    } else {
      // Install may predate an expanded bundled list; backfill missing keys
      // without touching the user's already-imported entries.
      await _seedMissingBundledSources();
    }
  }

  Future<void> _seedMissingBundledSources() async {
    final have = list.where((s) => s.bundleKey != null).map((s) => s.bundleKey!.toLowerCase()).toSet();
    var added = false;
    for (final key in bundledSourceKeys) {
      if (have.contains(key.toLowerCase())) continue;
      try {
        final text = await rootBundle.loadString('assets/js/sources/$key.js');
        await _importBundled(key, text);
        added = true;
      } catch (_) {}
    }
    if (added) await _save();
  }

  Future<void> _seedBundledSources() async {
    for (final key in bundledSourceKeys) {
      try {
        final text = await rootBundle.loadString('assets/js/sources/$key.js');
        await _importBundled(key, text);
      } catch (_) {}
    }
    if (list.isNotEmpty) {
      list.first.enabled = true;
      activeSourceId = list.first.id;
      await _save();
    }
  }

  Future<SourceMeta> _importBundled(String key, String scriptText) async {
    final meta = SourceMeta.parseMeta(scriptText);
    final id = 'bundled_$key';
    final file = File('${_dir.path}/$id.js');
    // 内置音源是覆盖同一个文件名，而这份文件引擎要整份读进 QuickJS：直接覆盖，
    // 撞上别处正在激活就可能读到半份脚本、初始化失败。先写临时文件再改名——
    // 同目录改名是原子的，读到的一定是完整的一份，要么旧要么新。
    // tmp 名字按时间戳分开：「全部更新」和后台那班可能同时在拉同一个音源，
    // 共用一个 tmp 会把两份内容写进同一个文件、再整份改名上去。
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsString(scriptText);
      await tmp.rename(file.path);
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    // 更新是「换掉同一件事的说明书」，不是新加一件事：这条原本启不启用得原样留着，
    // 否则「全部更新」跑完所有开关都齐刷刷变灰，下次开屏就没有音源了。
    final wasEnabled = list.where((e) => e.id == id).firstOrNull?.enabled ?? false;
    final sm = SourceMeta(
      id: id,
      name: meta['name']?.isNotEmpty == true ? meta['name']! : key,
      description: meta['description'] ?? '',
      version: meta['version'] ?? '',
      author: meta['author'] ?? '',
      homepage: meta['homepage'] ?? '',
      fileName: '$id.js',
      bundleKey: key,
      enabled: wasEnabled,
      lastUpdatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    list.removeWhere((e) => e.id == id);
    list.add(sm);
    await _save();
    return sm;
  }

  /// Fetch the newest version of a bundled source from any mirror.
  /// Returns the updated SourceMeta or throws on failure.
  ///
  /// [reactivate] 是给后台自动更新关的：正在放歌的时候把引擎换掉，取链要重新握手，
  /// 这一单队列会卡一下。脚本已经写回磁盘，下次开屏自然就用新的。
  Future<SourceMeta> refreshBundled(String id, {bool reactivate = true}) async {
    final meta = list.firstWhere((e) => e.id == id);
    final key = meta.bundleKey;
    if (key == null) throw Exception('非内置音源，无法自动更新');
    String? lastError;
    for (final template in _updateMirrors) {
      final url = template.replaceAll('{key}', key);
      try {
        final resp = await Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          responseType: ResponseType.plain,
        )).get<String>(url);
        final text = resp.data;
        if (text == null || text.length < 500) {
          lastError = '返回内容过短';
          continue;
        }
        final updated = await _importBundled(key, text);
        if (reactivate && activeSourceId == id) {
          // Reload the active engine so the new script takes effect.
          try {
            await activate(id);
          } catch (_) {}
        }
        return updated;
      } catch (e) {
        lastError = '$e';
      }
    }
    throw Exception(lastError ?? '所有镜像均失败');
  }

  /// 内置音源的接口说变就变，脚本超过几天没拉过就该换新了。以前这一步要她自己去
  /// 「音源管理」点「全部更新」，现在开屏在后台跑：一次最多三个，第一个连不上就收手
  /// （多半是压根没网，接着试只是白等），全程不出提示——更新上了她不需要知道，
  /// 更新不上手里还有原来那份能用。
  static const staleAfter = Duration(days: 7);
  bool _autoRefreshing = false;

  /// 从没拉过（时间戳 0）和超过 [staleAfter] 没拉过的，都算该更新。
  static bool staleAt(int lastUpdatedAt, DateTime now) =>
      now.difference(DateTime.fromMillisecondsSinceEpoch(lastUpdatedAt)) > staleAfter;

  /// 开屏那次音源激活。脚本是整份读进 QuickJS 的，更新写的是同一个文件——
  /// 两边撞上就可能出现「读到半份脚本、初始化失败、这次开屏没音源可用」，
  /// 所以自动更新先等它落定。由 main.dart 赋值，没有激活时是 null。
  Future<void>? activation;

  Future<int> autoRefreshIfStale() async {
    if (_autoRefreshing) return 0;
    _autoRefreshing = true;
    var done = 0;
    try {
      await (activation ?? Future<void>.value());
      final now = DateTime.now();
      final stale = list.where((e) => e.bundleKey != null && staleAt(e.lastUpdatedAt, now)).take(3).toList();
      for (final s in stale) {
        try {
          await refreshBundled(s.id, reactivate: false);
          done++;
        } catch (_) {
          break; // 第一个就拉不动，多半是没网；剩下两个只是接着白等
        }
      }
    } finally {
      _autoRefreshing = false;
    }
    return done;
  }

  Future<Map<String, String>> refreshAllBundled() async {
    final result = <String, String>{};
    for (final m in list.where((e) => e.bundleKey != null)) {
      try {
        await refreshBundled(m.id);
        result[m.name] = '已更新';
      } catch (e) {
        result[m.name] = '失败: $e';
      }
    }
    return result;
  }

  Future<void> _save() async {
    JsonFile.write(_indexFile, list.map((e) => e.toJson()).toList());
  }

  /// 生命周期钩子用：启用/禁用音源后立刻落盘，别让 rename 半途被杀留下空索引。
  void flushNow() => JsonFile.write(_indexFile, list.map((e) => e.toJson()).toList());

  /// 导入前的基本体检。群里转的「音源」经常其实是 json 曲库、一个网页，或者一段
  /// 完全不相干的脚本；直接收下只会多出一个永远启用不起来的条目，还不如当场拒绝。
  static void _assertSourceScript(String text) {
    if (text.length < 300) throw Exception('文件太小，不像音源脚本');
    final head = text.trimLeft();
    if (head.startsWith('<')) throw Exception('这是网页（HTML），音源要 .js 脚本文件');
    if (head.startsWith('{') || head.startsWith('[')) {
      throw Exception('这是 JSON 曲库配置，不是音源脚本；音源请用 .js 文件');
    }
    if (!text.contains('globalThis.lx') && !text.contains('EVENT_NAMES')) {
      throw Exception('脚本里没有洛雪音源接口（globalThis.lx），换一份再试');
    }
  }

  Future<SourceMeta> importScript(String scriptText) async {
    _assertSourceScript(scriptText);
    final meta = SourceMeta.parseMeta(scriptText);
    final id = 's${DateTime.now().millisecondsSinceEpoch}';
    final file = File('${_dir.path}/$id.js');
    await file.writeAsString(scriptText);
    final sm = SourceMeta(
      id: id,
      name: meta['name']?.isNotEmpty == true ? meta['name']! : '导入的源 $id',
      description: meta['description'] ?? '',
      version: meta['version'] ?? '',
      author: meta['author'] ?? '',
      homepage: meta['homepage'] ?? '',
      fileName: '$id.js',
    );
    list.add(sm);
    await _save();
    return sm;
  }

  Future<String?> readScript(SourceMeta m) async {
    if (m.fileName == null) return null;
    final f = File('${_dir.path}/${m.fileName}');
    return f.existsSync() ? f.readAsString() : null;
  }

  Future<void> remove(String id) async {
    final m = list.firstWhere((e) => e.id == id);
    list.remove(m);
    if (m.fileName != null) {
      try {
        await File('${_dir.path}/${m.fileName}').delete();
      } catch (_) {}
    }
    if (activeSourceId == id) {
      activeSourceId = null;
      LxEngine.active?.dispose();
      LxEngine.active = null;
    }
    await _save();
  }

  /// make this source active: load into engine
  Future<LxEngine?> activate(String id) async {
    final meta = list.firstWhere((e) => e.id == id);
    final script = await readScript(meta);
    if (script == null) return null;
    final engine = LxEngine();
    try {
      await engine.loadScript(
        script,
        name: meta.name,
        description: meta.description,
        version: meta.version,
        author: meta.author,
        homepage: meta.homepage,
      );
    } catch (e) {
      engine.dispose();
      rethrow;
    }
    if (!engine.inited) {
      final err = engine.initError;
      engine.dispose();
      throw Exception(err ?? '源初始化失败');
    }
    LxEngine.active?.dispose();
    LxEngine.active = engine;
    activeSourceId = id;
    // 换音源等于换了一批取链能力：之前「这首确实没有免费版」的判定作废，
    // 不然新源明明能播的歌还要被跳过整整一周。
    LibraryStore.instance.clearSwapDead();
    for (final s in list) {
      s.enabled = s.id == id;
    }
    await _save();
    return engine;
  }

  Future<void> deactivate() async {
    LxEngine.active?.dispose();
    LxEngine.active = null;
    activeSourceId = null;
    for (final s in list) {
      s.enabled = false;
    }
    await _save();
  }
}
