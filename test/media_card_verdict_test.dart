import 'package:flutter_test/flutter_test.dart';
import 'package:lyric_music/util/power_status.dart';

// 这一张表决定她在设置页上看到哪句话、点哪个按钮：判错方向比不判更糟。
void main() {
  const open = MediaCardState(notificationsOn: true, channelImportance: 4, posted: true);

  test('通知总开关关着时，别的都不用看', () {
    const st = MediaCardState(notificationsOn: false, channelImportance: 4, posted: false);
    expect(st.verdict(playing: true), MediaCardVerdict.notificationsOff);
    expect(st.verdict(playing: false), MediaCardVerdict.notificationsOff);
  });

  test('整罐开着、单是播放通道被静默，是另一种病', () {
    const st = MediaCardState(notificationsOn: true, channelImportance: 0, posted: false);
    expect(st.verdict(playing: true), MediaCardVerdict.channelBlocked);
  });

  test('在放歌但系统里没有卡，才是能重发救回来的那一种', () {
    const st = MediaCardState(notificationsOn: true, channelImportance: 4, posted: false);
    expect(st.verdict(playing: true), MediaCardVerdict.notPosted);
  });

  test('卡片已经贴在系统里', () {
    expect(open.verdict(playing: true), MediaCardVerdict.inSystem);
  });

  test('没放歌时不下结论，免得把「本来就没有卡」报成毛病', () {
    expect(open.verdict(playing: false), MediaCardVerdict.idle);
    expect(const MediaCardState().verdict(playing: false), MediaCardVerdict.idle);
  });

  test('安静通道不算病：只有 importance=0 才拦通知', () {
    const quiet = MediaCardState(notificationsOn: true, channelImportance: 2, posted: true);
    expect(quiet.verdict(playing: true), MediaCardVerdict.inSystem);
  });

  test('安卓 9 以下查不到卡时不算故障，通知开着就当作在', () {
    const old = MediaCardState(notificationsOn: true, channelImportance: 4);
    expect(old.verdict(playing: true), MediaCardVerdict.inSystem);
  });

  test('原生什么都没答上时不许报毛病', () {
    expect(const MediaCardState().verdict(playing: true), MediaCardVerdict.unknown);
  });
}
