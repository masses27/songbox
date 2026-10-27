import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/lx_engine.dart';
import '../../source/source_manager.dart';
import '../../util/humanize.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  final _manager = SourceManager.instance;
  bool _refreshingAll = false;
  final Set<String> _refreshingIds = {};

  bool _importing = false;

  /// 「从链接导入」那个输入框的控制器，页面关掉就得还给框架。
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFromClipboard() async {
    if (_importing) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _toast('剪贴板为空，请先复制音源脚本内容');
      return;
    }
    if (!text.contains('lx') && !text.contains('module') && text.length < 200) {
      _toast('剪贴板内容不像音源脚本');
      return;
    }
    setState(() => _importing = true);
    try {
      final meta = await _manager.importScript(text);
      _toast('已导入：${meta.name}');
    } catch (e) {
      _toast('导入失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    // 统一走 toast：时长、浮起位置、和播放条的避让都在那一处定，免得每个页面各写一份。
    toast(context, msg);
  }

  Future<void> _activate(SourceMeta m) async {
    _toast('正在初始化「${m.name}」…');
    try {
      final engine = await _manager.activate(m.id);
      final s = engine?.support;
      if (s != null) {
        _toast('启用成功：支持 ${s.sources.join('/')}，音质 ${s.qualitys.values.expand((e) => e).toSet().join('/')}');
      }
    } catch (e) {
      _toast('启用失败：${humanizeError(e)}');
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshOne(SourceMeta m) async {
    setState(() => _refreshingIds.add(m.id));
    try {
      final updated = await _manager.refreshBundled(m.id);
      _toast('「${updated.name}」已更新至 ${updated.version.isEmpty ? '最新版' : updated.version}');
    } catch (e) {
      _toast('更新失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _refreshingIds.remove(m.id));
    }
  }

  Future<void> _refreshAll() async {
    if (_refreshingAll) return;
    setState(() => _refreshingAll = true);
    try {
      final results = await _manager.refreshAllBundled();
      final ok = results.entries.where((e) => e.value == '已更新').length;
      _toast('共 ${results.length} 个内置音源，成功更新 $ok 个');
    } catch (e) {
      _toast('更新失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _refreshingAll = false);
    }
  }

  /// 删掉一个音源：误触菜单里那一项就会少一个源，先问一句。
  Future<void> _delete(SourceMeta m) async {
    final ok = await confirmAction(context,
        title: '删除「${m.name}」',
        message: m.bundleKey != null ? '删掉后点「全部更新」还能重新拉回来。' : '删掉后要重新导入才能再用。');
    if (!ok) return;
    await _manager.remove(m.id);
    if (!mounted) return;
    setState(() {});
    _toast('已删除「${m.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final engine = LxEngine.active;
    final bundled = _manager.list.where((e) => e.bundleKey != null).toList();
    final custom = _manager.list.where((e) => e.bundleKey == null).toList();
    return Scaffold(
      backgroundColor: AppTheme.sheetBg,
      appBar: AppBar(
        title: const Text('音源管理'),
        backgroundColor: AppTheme.pageBg,
      ),
      bottomNavigationBar: const PlayerBar(),
      body: RefreshIndicator(
        // 原来只是 setState，下拉一下什么也没发生；这里直接走真正的「全部更新」。
        onRefresh: _refreshAll,
        child: ListView(
          // 内置音源只有几行时列表还不足一屏，不给这个 physics 下拉根本拉不动，
          // 那句「下拉一下什么也没发生」就还留着。
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (engine != null && engine.inited)
              _statusCard('当前音源：${engine.support?.sources.join('、') ?? ''}', true)
            else
              _statusCard('网易云、QQ、B 站、酷狗的歌端内直连就能放，这一页可以先不管；'
                  '音源只是多接几个曲库的入口', false),
            const SizedBox(height: 12),
            _sectionHeader(
              title: '内置音源（可自动更新）',
              trailing: TextButton.icon(
                onPressed: _refreshingAll ? null : _refreshAll,
                icon: _refreshingAll
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync, size: 18),
                label: Text(_refreshingAll ? '更新中' : '全部更新'),
              ),
            ),
            if (bundled.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('内置音源缺失，请重新安装 APK。', style: TextStyle(color: AppTheme.textSecondary)),
              ),
            ...bundled.map(_sourceTile),
            const SizedBox(height: 16),
            _sectionHeader(title: '手动导入'),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _importing ? null : _importFromClipboard,
                    icon: _importing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.content_paste),
                    label: Text(_importing ? '正在导入…' : '从剪贴板导入'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importing ? null : _showUrlImport,
                    icon: const Icon(Icons.link),
                    label: const Text('从链接导入'),
                  ),
                ),
              ],
            ),
            if (custom.isNotEmpty) ...[
              const SizedBox(height: 16),
              _sectionHeader(title: '自定义音源'),
              ...custom.map(_sourceTile),
            ],
            const SizedBox(height: 24),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '提示：内置音源来自 pdone/lx-music-source 项目（GitHub），点「全部更新」或每行的刷新按钮可从 GitHub / jsDelivr 拉取最新版并自动重载。',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader({required String title, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
          ?trailing,
        ],
      ),
    );
  }

  Widget _statusCard(String text, bool ok) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.tile(ok ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0)),
        borderRadius: AppTheme.cardBorder,
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.info, color: ok ? Colors.green : Colors.orange),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _sourceTile(SourceMeta m) {
    final active = m.enabled;
    final refreshing = _refreshingIds.contains(m.id);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: active ? AppTheme.primary : AppTheme.pillBg,
          child: Icon(Icons.music_note, color: active ? Colors.white : AppTheme.textSecondary),
        ),
        title: Text(m.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${m.version}  ${m.description}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            if (m.bundleKey != null && m.lastUpdatedAt > 0)
              Text('上次更新：${_fmtTime(m.lastUpdatedAt)}', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
        isThreeLine: m.bundleKey != null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active) const Icon(Icons.check_circle, color: AppTheme.primary, size: 20),
            if (m.bundleKey != null)
              IconButton(
                tooltip: '更新此音源',
                onPressed: refreshing ? null : () => _refreshOne(m),
                icon: refreshing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 22),
              ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'activate') {
                  await _activate(m);
                } else if (v == 'delete') {
                  await _delete(m);
                }
              },
              itemBuilder: (context) => [
                if (!active) const PopupMenuItem(value: 'activate', child: Text('启用')),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _showUrlImport() async {
    if (_importing) return;
    _urlCtrl.clear();
    var note = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('从链接导入音源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _urlCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'https://…/xxx.js', labelText: '脚本地址'),
                keyboardType: TextInputType.url,
              ),
              TextButton.icon(
                // 长网址在手机上选中、复制、再对着另一边的地址栏敲进来，每一步都会错。
                // 链接已经复制过的时候，这里一步就填上；剪贴板空着也要当场说，
                // 不能按了没反应（提示条会被这层对话框盖住，所以写在框里）。
                onPressed: () async {
                  final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
                  if (t.isEmpty) {
                    setDialogState(() => note = '剪贴板里是空的，先复制脚本地址');
                    return;
                  }
                  _urlCtrl.text = t;
                  setDialogState(() => note = '已填上剪贴板里的地址');
                },
                icon: const Icon(Icons.content_paste, size: 18),
                label: const Text('粘剪贴板', style: TextStyle(fontSize: 12)),
              ),
              if (note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(note, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('导入')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // 下面要拿 context 说话：对话框关掉那一刻，这一页可能已经被退出去了。
    if (!mounted) return;
    final url = _urlCtrl.text.trim();
    // 原来是 if (url.isEmpty) return;：那一格没填的话对话框一关，什么提示都没有，
    // 看上去像导入失败、又像她记错了，只能从头再点一遍。
    if (url.isEmpty) {
      _toast('「脚本地址」那一格还是空的');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // 少敲的那截不用她回去补：提示条上直接给一颗「就这么试」。
      toast(context, '链接没有 http:// 或 https:// 开头',
          actionLabel: '补上 https:// 再试', onAction: () => _importFromUrl('https://$url'));
      return;
    }
    await _importFromUrl(url);
  }

  Future<void> _importFromUrl(String url) async {
    // 也可能是从提示条那颗「补上 https:// 再试」按进来的，隔了几秒，页面早退出去了。
    if (!mounted) return;
    try {
      setState(() => _importing = true);
      final resp = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
      )).get<String>(url);
      final meta = await _manager.importScript(resp.data ?? '');
      _toast('已导入：${meta.name}');
    } catch (e) {
      _toast('导入失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}
