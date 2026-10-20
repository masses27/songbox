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
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    // 原来是写给开发者看的「iOS 需后续接入 AVAudioUnitEQ 插件」，
                    // 她看到只会一头雾水。
                    child: Text('这台设备没有提供系统均衡器，暂时用不了这个功能。',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 14)),
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
                        setState(() {});
                      },
                    ),
                    const Divider(),
                    for (final preset in eqPresets)
                      ListTile(
                        leading: Icon(
                          player.eqPresetName == preset.name ? Icons.check_circle : Icons.circle_outlined,
                          color: player.eqPresetName == preset.name ? AppTheme.primary : AppTheme.textSecondary,
                        ),
                        title: Text(preset.name),
                        subtitle: Text(preset.gains.map((g) => g == 0 ? '0' : (g > 0 ? '+$g' : '$g')).join('  ')),
                        onTap: () async {
                          await player.applyPreset(preset);
                          setState(() {});
                        },
                      ),
                  ],
                ),
    );
  }
}
