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

  /// 通知栏那张控制卡本质是一条媒体通知，系统总开关关了它就出不来。
  static Future<bool> notificationsEnabled() async =>
      !supported || await _ask('notificationsEnabled') == true;

  static Future<bool> openNotificationSettings() async =>
      supported && await _ask('openNotificationSettings') == true;

  static Future<Object?> _ask(String method) async {
    try {
      return await _ch.invokeMethod(method);
    } catch (_) {
      return null;
    }
  }
}
