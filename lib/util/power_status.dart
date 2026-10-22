import 'dart:io';

import 'package:flutter/services.dart';

/// 息屏之后系统会不会掐掉后台网络，Dart 侧看不见，只能问原生。
///
/// 拿不到答案时一律按「没放行」处理：让她多点一次，比看不见这个问题强。
class PowerStatus {
  PowerStatus._();

  static const _ch = MethodChannel('com.wyj.music.lyric_music/power');

  static bool get supported => Platform.isAndroid;

  /// 是否已被排除在电池优化之外（= 息屏后后台网络不会被省电策略掐）。
  static Future<bool> ignoringBatteryOptimizations() async =>
      !supported || await _ask('batteryOptimizationIgnored') == true;

  /// 手机当前是否处于省电模式；即便我们已放行，这一档仍可能限网。
  static Future<bool> powerSaveMode() async => supported && await _ask('powerSaveMode') == true;

  /// 弹系统的「允许后台运行」授权框；ROM 屏蔽弹窗时原生会直接跳到能改的那一页。
  static Future<bool> askIgnoreBatteryOptimizations() async =>
      supported && await _ask('askIgnoreBatteryOptimization') == true;

  static Future<bool> openBatterySettings() async => supported && await _ask('openBatterySettings') == true;

  /// 下拉菜单里那张播放卡现在到底处在哪一步（证据见 [MediaCardState]）。
  static Future<MediaCardState> mediaCardState() async {
    if (!supported) return const MediaCardState();
    final raw = await _ask('mediaCardState');
    if (raw is! Map) return const MediaCardState();
    final notes = <MediaCardNote>[];
    final rawNotes = raw['notes'];
    // 原生给的是 List<Map>，安卓 9 以下没查、给空表；解析不动就当没查到。
    if (rawNotes is List) {
      for (final e in rawNotes) {
        if (e is! Map) continue;
        notes.add(
          MediaCardNote(
            id: e['id'] is int ? e['id'] as int : -1,
            channel: '${e['ch'] ?? ''}',
            foregroundService: e['fgs'] == true,
          ),
        );
      }
    }
    // 系统认得的我们那些栏：卡没贴上去时，「一栏都没有」和「有一栏但不叫这名字」
    // 是两种完全不同的毛病，光靠 channel 一个数分不出来。
    final channels = <String>[];
    final rawChannels = raw['channels'];
    if (rawChannels is List) {
      for (final e in rawChannels) {
        if (e is! Map) continue;
        channels.add('${MediaCardNote.shorten('${e['id'] ?? ''}')}:${e['imp']}');
      }
    }
    return MediaCardState(
      notificationsOn: raw['notifications'],
      channelImportance: raw['channel'],
      posted: raw['posted'],
      notificationsPaused: raw['paused'],
      serviceForeground: raw['service'],
      serviceStarted: raw['serviceStarted'],
      musicActive: raw['music'],
      listenerAlive: raw['listener'],
      notes: notes,
      channels: channels,
    );
  }

  /// 播放器报过 idle 之后，原生那座桥多半已经被拆了；把它接回来。
  ///
  /// 返回值：`ok` 接回来了、`alive` 本来就活着、`missing` 原生找不到那个对象
  /// （插件被改名之类）、`error` 装回去时抛了。问不到答案时按 `missing` 算。
  static Future<String> reattachMediaListener() async {
    if (!supported) return 'alive';
    final raw = await _ask('reattachMediaListener');
    return raw is String ? raw : 'missing';
  }

  static Future<bool> openNotificationSettings() async =>
      supported && await _ask('openNotificationSettings') == true;

  /// 「播放控制」这一栏被单独静默时，直达那一栏，别让她在整罐通知设置里翻。
  static Future<bool> openChannelSettings() async => supported && await _ask('openChannelSettings') == true;

  static Future<Object?> _ask(String method) async {
    try {
      return await _ch.invokeMethod(method);
    } catch (_) {
      return null;
    }
  }
}

/// 控制中心/锁屏那张播放卡的证据，都只查我们自己发的通知和通道，所以不要新权限。
class MediaCardState {
  const MediaCardState({
    this.notificationsOn,
    this.channelImportance,
    this.posted,
    this.notificationsPaused,
    this.serviceForeground,
    this.serviceStarted,
    this.musicActive,
    this.listenerAlive,
    this.notes = const [],
    this.channels = const [],
    this.bridge,
    this.bridgeErrors = 0,
    this.bridgeError,
  });

  /// 系统让不让这个 App 发通知；null = 原生没答上。
  final bool? notificationsOn;

  /// 「播放控制」通道的响动等级（安卓的 IMPORTANCE_*，0 = 被单独关掉）；
  /// null = 系统太老，或从安装到现在还没放过歌。
  final int? channelImportance;

  /// 此刻系统里有没有我们发出去的那张卡；null = 安卓 9 以下查不到。
  final bool? posted;

  /// 系统级的「暂停通知」开关（安卓 13 起）；开着时通知照发、就是不上屏。
  final bool? notificationsPaused;

  /// 播放服务此刻是不是真以「前台服务」身份活着；null = ROM 不答这个查询。
  final bool? serviceForeground;

  /// 播放服务有没有被 startService 起过；null = ROM 不答这个查询。
  /// false = 只是被应用绑着，说明「进入播放态」那一趟连第一步都没走到；
  /// true 而 [serviceForeground] 是 false = 走到了、后半段没能把通知挂上。
  final bool? serviceStarted;

  /// 系统里此刻有没有音乐在出声，用来分清「歌没在放」和「歌在放但服务没起来」。
  final bool? musicActive;

  /// 卡上的按钮能不能落到应用里：原生那半截桥（audio_service 的 listener）还在不在。
  /// false = 桥被 idle 拆了，卡照样显示、照样在放，但按什么都不响应。
  /// null = 原生反射问不到（插件被改名，或系统不让读那个私有字段）。
  final bool? listenerAlive;

  /// 本应用此刻挂在系统里的每一条通知（含落在别的通道上的）。
  final List<MediaCardNote> notes;

  /// 系统里我们那些通道，形如 `playback:2`；通道一个都没有 = 服务没走到发通知那步。
  final List<String> channels;

  /// 我们这一侧想要的状态，形如 `=true/ready`（播放中且已就绪）。原生查不到这一项，
  /// 它说的是「播放器想不想播」，不是「服务收到了什么」——服务那边收不到东西时，
  /// 这里照样是绿的，所以它只用来和 [bridgeErrors] 对照着看。
  final String? bridge;

  /// 和播放服务说话时错了几次。那座桥把异常全吞进自己的流里，不接住就一点痕迹都不留。
  final int bridgeErrors;

  /// 头一次桥接报错的原文（截断过）。异常名字本身就指向断点在哪一跳，
  /// 所以直接印在取证行上，省得她再去翻日志页。
  final String? bridgeError;

  /// 原生查不到的那三样由播放层补进来（它才知道我们要的是什么状态、桥报过几次错、
  /// 头一次报的是什么）。
  MediaCardState withBridge(String? bridge, int errors, String? firstError) => MediaCardState(
        notificationsOn: notificationsOn,
        channelImportance: channelImportance,
        posted: posted,
        notificationsPaused: notificationsPaused,
        serviceForeground: serviceForeground,
        serviceStarted: serviceStarted,
        musicActive: musicActive,
        listenerAlive: listenerAlive,
        notes: notes,
        channels: channels,
        bridge: bridge,
        bridgeErrors: errors,
        bridgeError: firstError,
      );

  MediaCardVerdict verdict({required bool playing}) {
    if (notificationsOn == false) return MediaCardVerdict.notificationsOff;
    if (channelImportance == 0) return MediaCardVerdict.channelBlocked;
    if (notificationsPaused == true) return MediaCardVerdict.notificationsPaused;
    if (!playing) return MediaCardVerdict.idle;
    if (posted == false) {
      // 卡在系统里，只是落在我们没预料到的那一栏上（通道 id 被 ROM 改写时有这种局面）。
      if (notes.any((n) => n.channel != _playbackChannel)) {
        return MediaCardVerdict.postedElsewhere;
      }
      // 前台服务还活着就必然挂着通知，这是平台规矩；查不到就是手机不给上屏，
      // 重发一万次也没用，别再往自己身上找。
      if (serviceForeground == true) return MediaCardVerdict.hiddenByRom;
      return MediaCardVerdict.notPosted;
    }
    // 总开关和通道都说不上话时，「查不到卡」不能当成病来报。
    if (posted == null && notificationsOn == null) return MediaCardVerdict.unknown;
    return MediaCardVerdict.inSystem;
  }

  /// 一行原始证据，写进日志用。判断交给 verdict，这里只交代事实，
  /// 让她截一张图或导一次日志就能定案，不必再来回猜。
  String get detail {
    // 字段是 final 也提升不了类型，先落成局部变量再判空。
    final svc = switch (serviceForeground) {
      null => '?',
      true => '在',
      false => '不在',
    };
    // 起没起过服务要单说：它分得开「那一趟没走到」和「走到了却没挂上通知」。
    final started = switch (serviceStarted) {
      null => '',
      true => '·起过',
      false => '·没起',
    };
    final notesText = notes.isEmpty
        ? '无'
        : notes.map((n) => '${n.id}@${n.shortChannel}${n.foregroundService ? '/FGS' : ''}').join(',');
    return '开关${_yn(notificationsOn)} 通道${channelImportance ?? '-'} '
        '服务$svc$started '
        '出声${_yn(musicActive)} 挂着的通知[$notesText] 有栏[${_listText(channels)}]'
        // 卡上的键通不通只有原生知道：这一项是关的时候，界面照常放歌、卡照常显示，
        // 按了却一点反应都没有 —— 和她这次说的一模一样。
        ' 按键${_yn(listenerAlive)}'
        // 上一版这里印的是插件的 playbackStateStream，后来查明那条流只有走旧版 backgroundTask
        // 才会被接上，我们这条路读到的永远是出厂默认值，白占半行字，换成我们自己这一侧的事实。
        '${bridge == null ? '' : ' 要播$bridge'}'
        '${bridgeErrors > 0 ? ' 桥错$bridgeErrors${bridgeError == null ? '' : '·$bridgeError'}' : ''}'
        '${notificationsPaused == true ? ' 暂停通知中' : ''}';
  }

  static String _listText(List<String> items) => items.isEmpty ? '无' : items.join(',');

  static String _yn(bool? v) => v == null ? '?' : (v ? '开' : '关');
}

/// 本应用挂在系统里的一条通知：落在哪一栏、是不是前台服务通知。
class MediaCardNote {
  const MediaCardNote({required this.id, required this.channel, this.foregroundService = false});

  final int id;
  final String channel;

  /// 带 FLAG_FOREGROUND_SERVICE 的通知是前台服务那张，安卓 14 起用户才能顺手划掉它。
  final bool foregroundService;

  /// 通道 id 前缀就是我们的包名，日志里只留后面那截，一行放得下三条。
  String get shortChannel => shorten(channel);

  static String shorten(String id) => id.replaceFirst('com.wyj.music.lyric_music.', '');
}

const _playbackChannel = 'com.wyj.music.lyric_music.playback';

enum MediaCardVerdict {
  /// 通知总开关被关着。
  notificationsOff,

  /// 整罐开着，单是「播放控制」这一栏被静默了。
  channelBlocked,

  /// 手机开了「暂停通知」，通知全都不上屏。
  notificationsPaused,

  /// 歌在放，卡片却没贴到系统里 —— 重发一次能救。
  notPosted,

  /// 卡片在系统里，只是不在我们认得的那一栏上。
  postedElsewhere,

  /// 前台服务活着、通知却没上屏：手机的拦截策略，App 这边发出去了。
  hiddenByRom,

  /// 卡片已经在系统里了；控制中心那一格还不显示就是 ROM 的媒体模块没接上。
  inSystem,

  /// 没在放歌，这一格问不出什么。
  idle,

  /// 原生没答上（系统太老或通道调用失败）。
  unknown,
}
