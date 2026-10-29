import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lyric_music/settings/app_settings.dart';

// 「关于」和日志里那句版本读的是 AppSettings.appVersion 这个常量，不是 pubspec。
// 安卓那条 build.sh 打包前会按 pubspec 改写它，Windows 那条由 Actions 直接编提交的
// 源码、没人改写——v0.8.43 就是这么编出两份自报 v0.8.42 的桌面产物的。workflow 里
// 加了闸门，这里再钉一道：不一致时本机 analyze/test 就该过不去，而不是发出去才对上。
void main() {
  test('界面里那个版本号跟 pubspec 是同一个', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里没读到 version');
    expect(AppSettings.appVersion, m!.group(1),
        reason: 'AppSettings.appVersion 还停在旧版本号：桌面版会自报一个跟 Release 对不上的版本');
  });
}
