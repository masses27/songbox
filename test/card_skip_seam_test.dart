import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:songbox_audio_background/just_audio_background.dart';

// third_party 里那份副本是「卡上两个箭头归谁管」的唯一落点，而它会跟着上游版本一起被换掉。
// 这里把改动的三处钉死：日后升上游时这一测过不去，就是在提醒人重新对齐，而不是等她手机上
// 按了没反应才发现。测试跑在项目根目录，所以按相对路径读文件。
const _fork = 'third_party/songbox_audio_background/lib/just_audio_background.dart';
const _forkPubspec = 'third_party/songbox_audio_background/pubspec.yaml';

void main() {
  test('钩子不挂时副本行为与上游一致（没人赋值就不接管切歌）', () {
    expect(JustAudioBackground.onSkipToNext, isNull);
    expect(JustAudioBackground.onSkipToPrevious, isNull);
  });

  test('副本改的三处都还在：钩子、skipTo* 落点、控件表', () {
    final src = File(_fork).readAsStringSync();
    expect(src, contains('Future<void> Function()? onSkipToNext'));
    expect(src, contains('Future<void> Function()? onSkipToPrevious'));
    expect(src, contains('final hook = JustAudioBackground.onSkipToNext;'));
    expect(src, contains('final hook = JustAudioBackground.onSkipToPrevious;'));
    // 控件表这一处最容易被当成无关改动丢掉：不进表，系统就不认为这两键可用。
    expect(src, contains('if (hasPrevious || JustAudioBackground.onSkipToPrevious != null)'));
    expect(src, contains('if (hasNext || JustAudioBackground.onSkipToNext != null)'));
  });

  test('改过源码的副本不顶着上游名字', () {
    expect(File(_forkPubspec).readAsStringSync(), contains('name: songbox_audio_background'));
  });
}
