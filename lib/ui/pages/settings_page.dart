import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../download/download_manager.dart';
import '../../library/library_store.dart';
import '../../player/audio_prefetch.dart';
import '../../player/player_service.dart';
import '../../settings/app_settings.dart';
import '../../util/power_status.dart';
import '../player/player_bar.dart';
import '../theme.dart';
import '../widgets.dart';
import 'diagnostic_page.dart';

/// 播放设置 — quality preference, cache clearing, search history, version.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _clearCache(BuildContext context) async {
    final dm = context.read<DownloadManager>();
    // 预取下来还没播到的歌也算缓存，一起清掉。
    final bytes = await DownloadManager.deleteImageCache() + await AudioPrefetch.instance.clearAll();
    final musicBytes = await DownloadManager.musicDirBytes();
    if (!context.mounted) return;
    final doMusic = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除缓存'),
        content: Text('图片与预取歌曲缓存 ${_fmt(bytes)}\n已下载音乐 ${_fmt(musicBytes)}\n\n'
            '${musicBytes == 0 ? '暂时还没有下载文件。' : '是否连同已下载的音乐一起删除？'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('只清缓存')),
          if (musicBytes > 0)
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('全部删除')),
        ],
      ),
    );
    if (doMusic == true) await dm.deleteAllDownloads();
    if (!context.mounted) return;
    // 报一个真实清出来的体积，比「已清理」三个字有用：她能确认手机存储确实松动了。
    final freed = bytes + (doMusic == true ? musicBytes : 0);
    toast(
      context,
      '已清出 ${_fmt(freed)}${doMusic == true ? '' : '（歌曲收藏与音源设置保留）'}',
    );
  }

  static String _fmt(int bytes) {
    if (bytes <= 0) return '0 KB';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('播放设置')),
      backgroundColor: AppTheme.pageBg,
      bottomNavigationBar: const PlayerBar(),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text('播放音质', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          RadioGroup<String>(
            groupValue: settings.quality,
            onChanged: (v) {
              if (v == null) return;
              settings.setQuality(v);
              final playing = PlayerService.instance.current;
              if (playing != null && !LibraryStore.instance.hasLocalFile(playing)) {
                toast(context, '下一首起使用新音质，当前这首继续播放');
              }
            },
            child: Column(
              children: [
                for (final q in AppSettings.qualities)
                  RadioListTile<String>(
                    value: q,
                    title: Text(_qualityName(q)),
                    subtitle: Text(_qualityHint(q),
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    activeColor: AppTheme.primary,
                  ),
              ],
            ),
          ),
          Divider(height: 24, color: AppTheme.divider),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('外观', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final t in AppSettings.themeValues)
                  _ThemeChip(
                    label: switch (t) {
                      'light' => '浅色',
                      'dark' => '深色',
                      _ => '跟随系统',
                    },
                    selected: settings.theme == t,
                    onTap: () => settings.setTheme(t),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('深色在夜里听歌不刺眼；跟随系统会跟着手机切换。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Divider(height: 24, color: AppTheme.divider),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text('播放行为', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            value: settings.autoSkipFailed,
            onChanged: settings.setAutoSkipFailed,
            activeThumbColor: AppTheme.primary,
            title: const Text('自动跳过放不出的歌'),
            subtitle: Text('遇到会员专享或链接失效的曲子时继续往下放，不在这里停住',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.vipAutoScan,
            onChanged: settings.setVipAutoScan,
            activeThumbColor: AppTheme.primary,
            title: const Text('会员歌自动找免费版'),
            subtitle: Text('换队列时在后台一次性把整单的会员歌换成能播的同一版本，结果会存下来复用',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.preloadNext,
            onChanged: settings.setPreloadNext,
            activeThumbColor: AppTheme.primary,
            title: const Text('提前备好下一首'),
            subtitle: Text('快播完时把下一首先取回手机，切歌立刻出声、不留空白；'
                '代价是多用一首歌的流量，省流量时可以关掉',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          SwitchListTile(
            value: settings.confirmBeforeDownload,
            onChanged: settings.setConfirmBeforeDownload,
            activeThumbColor: AppTheme.primary,
            title: const Text('下载前先问一句'),
            subtitle: Text('用移动网络时不容易察觉，无损一首几十兆',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          const _BackgroundRow(),
          const _NotificationRow(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('小米、OPPO 还要在「最近任务」里把听歌小窝往下拉锁定，'
                '否则一键清理会连着把后台网络一起断掉。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('音源自检'),
            subtitle: Text('逐个问一遍网易云、QQ、音源脚本、B 站、酷狗，看这个网络上能不能拿到整首；'
                '同一首歌换个网络结果可能不一样，跑一次十几秒',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DiagnosticPage()),
            ),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('搜索历史'),
            subtitle: Text(settings.searchHistory.isEmpty ? '暂无记录' : '共 ${settings.searchHistory.length} 条',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            trailing: settings.searchHistory.isEmpty
                ? null
                : TextButton(
                    onPressed: () {
                      // 抄一份再清：searchHistory 是设置里那份活的列表，直接传过去会被清成空的。
                      final snap = List<String>.from(settings.searchHistory);
                      settings.clearSearchHistory();
                      toast(context, '已清空搜索历史',
                          actionLabel: '撤销', onAction: () => settings.restoreSearchHistory(snap));
                    },
                    child: const Text('清空'),
                  ),
          ),
          ListTile(
            title: const Text('清除缓存'),
            subtitle: Text('封面与预取的歌曲缓存、已下载音乐',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            onTap: () => _clearCache(context),
          ),
          Divider(height: 24, color: AppTheme.divider),
          ListTile(
            title: const Text('关于'),
            subtitle: Text('听歌小窝 v${AppSettings.appVersion}\n'
                '网易云、QQ 的歌在端内直连播放，全程匿名，不需要登录任何账号；'
                '会员专享的会自动换成 B 站同一首的整首；'
                '「音源管理」只是多接几个曲库的入口，不启用也能听。',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _qualityName(String q) => switch (q) {
        '128k' => '标准 128k',
        'flac' => '无损 flac',
        _ => '高清 320k',
      };

  String _qualityHint(String q) => switch (q) {
        '128k' => '最省流量，任何曲库都能放',
        'flac' => '音质最好，只有部分歌曲提供，加载更慢',
        _ => '默认推荐，流量下也比较合适',
      };
}

/// 息屏之后系统会不会掐掉后台网络，只有原生侧知道。这一行把状态摊开，并且直接
/// 把她带到能放行的那一页；从授权框或厂商设置页回来时重新问一次，改完立刻看得见。
class _BackgroundRow extends StatefulWidget {
  const _BackgroundRow();

  @override
  State<_BackgroundRow> createState() => _BackgroundRowState();
}

class _BackgroundRowState extends State<_BackgroundRow> with WidgetsBindingObserver {
  bool? _ignoring;
  bool _powerSave = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final ignoring = await PowerStatus.ignoringBatteryOptimizations();
    final save = await PowerStatus.powerSaveMode();
    if (!mounted) return;
    setState(() {
      _ignoring = ignoring;
      _powerSave = save;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ignoring = _ignoring;
    final ok = ignoring == true;
    return ListTile(
      title: const Text('息屏后台播放'),
      subtitle: Text(
        ignoring == null
            ? '正在确认系统的后台限制…'
            : ok
                ? (_powerSave
                    ? '已允许后台运行；不过手机现在在省电模式，仍可能限制网络'
                    : '已允许后台运行，息屏也能连着网继续放')
                : '系统还在限制后台网络，息屏后容易连不上、歌就停了',
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: ignoring == null
          ? null
          : ok
              ? Icon(Icons.verified_outlined, color: AppTheme.primary)
              : TextButton(
                  onPressed: () => PowerStatus.askIgnoreBatteryOptimizations(),
                  child: const Text('去放行'),
                ),
      onTap: ok || ignoring == null ? null : () => PowerStatus.askIgnoreBatteryOptimizations(),
    );
  }
}

/// 通知栏那张控制卡就是一条媒体通知：系统把通知总开关关掉时它整个不出现，
/// 而她不会知道是这里被关了。状态直接摊开，点一下带到通知设置页。
class _NotificationRow extends StatefulWidget {
  const _NotificationRow();

  @override
  State<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<_NotificationRow> with WidgetsBindingObserver {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final enabled = await PowerStatus.notificationsEnabled();
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return ListTile(
      title: const Text('通知栏控制卡'),
      subtitle: Text(
        enabled == null
            ? '正在确认通知权限…'
            : enabled
                ? '下拉通知栏（锁屏也一样）能看到封面、歌名，直接暂停继续和拖进度；'
                    '切歌还是在应用里点'
                : '通知被系统关着，下拉看不到播放控制卡',
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: enabled == null
          ? null
          : enabled
              ? Icon(Icons.notifications_active_outlined, color: AppTheme.primary)
              : TextButton(onPressed: PowerStatus.openNotificationSettings, child: const Text('去开启')),
      onTap: enabled == true || enabled == null ? null : () => PowerStatus.openNotificationSettings(),
    );
  }
}

/// 主题选择的小药丸。自己画而不用 ChoiceChip：选中态的颜色要跟/// AppTheme 走，Material 的 chip 在深色底上分不清哪一个是当前项。
class _ThemeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.pillBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? AppTheme.primary : AppTheme.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}
