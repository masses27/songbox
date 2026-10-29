import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../util/app_log.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';

/// 听歌日志页 —— 手机上「这首放不出」到底发生了什么，只有这台机器知道。
///
/// 这一页存在的意义是把那段东西变成一句话能发给我的证据：打开、点复制、粘贴发送，
/// 不用她描述「刚才那首后来又能放了」这种我永远对不上号的现象。
/// 内容里只有时间、歌名、走到哪一步、结果；没有 cookie，也没有播放链接。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  String _text = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await AppLog.tail(lines: 800);
    if (!mounted) return;
    setState(() {
      _text = t;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    final all = await AppLog.exportText();
    await Clipboard.setData(ClipboardData(text: all));
    if (!mounted) return;
    toast(context, '已复制整段日志，粘到 POPO 发我就行');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ],
      ),
      backgroundColor: AppTheme.pageBg,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _text.isEmpty
              ? EmptyState(
                  message: '还没有记下什么。播几首歌、或者遇到一次放不出，这里就有内容了',
                  icon: Icons.description_outlined,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: SelectableText(
                    _text,
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.55,
                        fontFamily: 'monospace',
                        color: AppTheme.textPrimary),
                  ),
                ),
      // 这一页也得挂着播放条：她从播放页一路走到这里看证据，歌还在放，条却没了，
      // 看上去就像歌自己停了。播放条让下面那行自己避系统导航条，它就不必再垫一次。
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PlayerBar(reserveNavInset: false),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      // 刚清过空的时候按下去只会复制一段抬头，她还以为复制成功了 ——
                      // 没内容就把按钮关掉，比弹一条没用的提示明白得多。
                      onPressed: _text.isEmpty ? null : _copy,
                      icon: const Icon(Icons.copy_all, size: 18),
                      label: const Text('复制全部发我'),
                      style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: _text.isEmpty
                        ? null
                        : () async {
                            await AppLog.clear();
                            if (!mounted) return;
                            setState(() => _loading = true);
                            _load();
                          },
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
