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

  /// 下拉菜单里那张播放卡现在到底处在哪一步（三份证据见 [MediaCardState]）。
  static Future<MediaCardState> mediaCardState() async {
    if (!supported) return const MediaCardState();
    final raw = await _ask('mediaCardState');
    if (raw is! Map) return const MediaCardState();
    return MediaCardState(
      notificationsOn: raw['notifications'],
      channelImportance: raw['channel'],
      posted: raw['posted'],
    );
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

/// 控制中心/锁屏那张播放卡的三份证据，都只查我们自己发的通知，所以不要新权限。
class MediaCardState {
  const MediaCardState({this.notificationsOn, this.channelImportance, this.posted});

  /// 系统让不让这个 App 发通知；null = 原生没答上。
  final bool? notificationsOn;

  /// 「播放控制」通道的响动等级（安卓的 IMPORTANCE_*，0 = 被单独关掉）；
  /// null = 系统太老，或从安装到现在还没放过歌。
  final int? channelImportance;

  /// 此刻系统里有没有我们发出去的那张卡；null = 安卓 9 以下查不到。
  final bool? posted;

  MediaCardVerdict verdict({required bool playing}) {
    if (notificationsOn == false) return MediaCardVerdict.notificationsOff;
    if (channelImportance == 0) return MediaCardVerdict.channelBlocked;
    if (!playing) return MediaCardVerdict.idle;
    if (posted == false) return MediaCardVerdict.notPosted;
    // 总开关和通道都说不上话时，「查不到卡」不能当成病来报。
    if (posted == null && notificationsOn == null) return MediaCardVerdict.unknown;
    return MediaCardVerdict.inSystem;
  }
}

enum MediaCardVerdict {
  /// 通知总开关被关着。
  notificationsOff,

  /// 整罐开着，单是「播放控制」这一栏被静默了。
  channelBlocked,

  /// 歌在放，卡片却没贴到系统里 —— 重发一次能救。
  notPosted,

  /// 卡片已经在系统里了；控制中心那一格还不显示就是 ROM 的媒体模块没接上。
  inSystem,

  /// 没在放歌，这一格问不出什么。
  idle,

  /// 原生没答上（系统太老或通道调用失败）。
  unknown,
}
