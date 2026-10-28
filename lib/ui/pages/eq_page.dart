import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../player/player_service.dart';
import '../player/player_bar.dart';
import '../theme.dart';

class EqPage extends StatefulWidget {
  const EqPage({super.key});

  @override
  State<EqPage> createState() => _EqPageState();
}

class _EqPageState extends State<EqPage> {
  bool? _supported;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = await context.read<PlayerService>().eqSupported();
    if (!mounted) return;
    setState(() => _supported = ok);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    return Scaffold(
      appBar: AppBar(title: const Text('均衡器'), backgroundColor: AppTheme.pageBg),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: _supported == null
          ? const Center(child: CircularProgressIndicator())
          : _supported == false
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    // 原来是写给开发者看的「iOS 需后续接入 AVAudioUnitEQ 插件」，
                    // 她看到只会一头雾水。
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('这台设备没有提供系统均衡器，暂时用不了这个功能。\n'
                            '换一首歌之后、或者系统更新之后有时就有了，可以再问一次。',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 10),
                        TextButton(onPressed: _checkBusy ? null : _recheck, child: Text(_checkBusy ? '正在问…' : '再问一次')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    SwitchListTile(
                      title: const Text('启用均衡器'),
                      subtitle: Text('当前预设：${player.eqPresetName}'),
                      value: player.eqPresetName != '关闭',
                      onChanged: (v) async {
                        if (v) {
                          await player.applyPreset(eqPresets.firstWhere((p) => p.name == '流行'));
                        } else {
                          await player.disableEq();
                        }
                        // 挂效果器要等一次本机调用，这期间她可能已经退出去了。
                        if (!mounted) return;
                        setState(() {});
                      },
                    ),
                    // 挂不上原来是一声不吭的：开关自己弹回去，屏幕上不留一句为什么。
                    if (player.eqError != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(player.eqError!,
                            style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A8A))),
                      ),
                    const Divider(),
                    for (final preset in eqPresets)
                      ListTile(
                        leading: Icon(
                          player.eqPresetName == preset.name ? Icons.check_circle : Icons.circle_outlined,
                          color: player.eqPresetName == preset.name ? AppTheme.primary : AppTheme.textSecondary,
                        ),
                        title: Text(preset.name),
                        // 五个 dB 数字她读不出听感差别，这一句才是选预设的依据。
                        subtitle: Text(preset.desc.isEmpty
                            ? preset.gains.map((g) => g == 0 ? '0' : (g > 0 ? '+$g' : '$g')).join('  ')
                            : preset.desc, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        onTap: () async {
                          await player.applyPreset(preset);
                          if (!mounted) return;
                          setState(() {});
                        },
                      ),
                  ],
                ),
    );
  }

  bool _checkBusy = false;

  /// 「再问一次」：某些定制 ROM 要等第一次真正接上播放器之后才给出均衡器通道。
  Future<void> _recheck() async {
    setState(() => _checkBusy = true);
    await _check();
    if (mounted) setState(() => _checkBusy = false);
  }
}
