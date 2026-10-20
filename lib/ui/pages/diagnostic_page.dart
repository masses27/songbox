import 'package:flutter/material.dart';

import '../../music_sdk/source_probe.dart';
import '../../settings/app_settings.dart';
import '../player/player_bar.dart';
import '../theme.dart';

/// 音源自检：把每个源各问一次，服务器回什么就摊什么。
///
/// 之所以放在 App 里而不是我在电脑上跑：这些接口的拦不拦是按出口 IP 决定的
/// （酷狗的行为验证就是这样），家里的宽带和手机流量各是一种结果。
class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  static const _steps = <({String label, Future<ProbeResult> Function() run})>[
    (label: '网易云 端内直连', run: SourceProbe.netease),
    (label: 'QQ 端内直连', run: SourceProbe.tencent),
    (label: '音源脚本', run: SourceProbe.lxSource),
    (label: 'B 站 整首兜底', run: SourceProbe.bilibili),
    (label: '酷狗 概念版', run: SourceProbe.kugou),
  ];

  final _results = <String, ProbeResult>{};
  bool _busy = false;
  bool _done = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _done = false;
      _results.clear();
    });
    for (final step in _steps) {
      try {
        final r = await step.run();
        if (!mounted) return;
        setState(() => _results[step.label] = r);
      } catch (e) {
        // 每个探测自己已经兜住了，走到这里只能是设备身份那一步炸了。
        if (!mounted) return;
        setState(() => _results[step.label] = (
              label: step.label,
              ok: false,
              warn: false,
              message: '这一步没跑起来',
              raw: '$e',
            ));
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final quality = AppSettings.instance.quality;
    final okCount = _results.values.where((r) => r.ok).length;
    // 不通的里面再分一刀：「用不上」的那些不该算进「还差几项」。
    final inert = _results.values.where((r) => !r.ok && r.warn).length;
    final actionable = _results.length - okCount - inert;
    return Scaffold(
      appBar: AppBar(title: const Text('音源自检')),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              '逐个问一遍各个曲库：能不能搜到、能不能拿到整首的播放地址。'
              '同一首歌在公司网和家里 WiFi 上的结果可能不一样，'
              '所以换到哪个网络都可以再跑一次。当前音质：$quality。',
              style: TextStyle(fontSize: 12, height: 1.6, color: AppTheme.textSecondary),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, size: 20),
              label: Text(_busy ? '正在检查…' : _done ? '再跑一次' : '开始检查'),
              style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            ),
          ),
          if (_done)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${_results.length} 项里 $okCount 项拿到了能直接播的地址。'
                '${actionable > 0 ? '还有 $actionable 项不通，值得看一眼。' : '不通的那几项本来就用不上，不用管。'}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          for (final step in _steps) _Row(step: step, result: _results[step.label], busy: _busy),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final ({String label, Future<ProbeResult> Function() run}) step;
  final ProbeResult? result;
  final bool busy;

  const _Row({required this.step, required this.result, required this.busy});

  @override
  Widget build(BuildContext context) {
    final r = result;
    // 三种图标：绿勾=通；橙色感叹号=不通、值得看一眼；灰色 i=不通但这一层用不上。
    // 少了最后这一档，「音源脚本」「酷狗」会永远红着，而它们红着不影响听歌。
    final icon = r == null
        ? (busy
            ? Icon(Icons.radio_button_unchecked, color: AppTheme.textSecondary, size: 20)
            : Icon(Icons.hourglass_empty, color: AppTheme.textSecondary, size: 20))
        : r.ok
            ? Icon(Icons.check_circle_outline, color: AppTheme.primary, size: 20)
            : r.warn
                ? Icon(Icons.info_outline, color: AppTheme.textSecondary, size: 20)
                : const Icon(Icons.error_outline, color: Colors.orange, size: 20);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      shape: const RoundedRectangleBorder(borderRadius: AppTheme.cardBorder),
      child: r == null
          ? ListTile(
              leading: icon,
              title: Text(step.label, style: const TextStyle(fontSize: 14)),
              subtitle: Text(busy ? '正在请求…' : '还没跑',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            )
          : ExpansionTile(
              leading: icon,
              title: Text(r.label, style: const TextStyle(fontSize: 14)),
              subtitle: Text(r.message, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  r.raw.isEmpty ? '（没有更多信息）' : r.raw,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
    );
  }
}
