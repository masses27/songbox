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

  test('手机开着「暂停通知」是另一种病，重发没用', () {
    const st = MediaCardState(
      notificationsOn: true,
      channelImportance: 4,
      posted: false,
      notificationsPaused: true,
    );
    expect(st.verdict(playing: true), MediaCardVerdict.notificationsPaused);
    // 没在放歌时仍然不报毛病：那时候本来就没有卡。
    expect(st.verdict(playing: false), MediaCardVerdict.notificationsPaused);
  });

  test('卡挂在另一栏上，别说成「没贴到系统里」', () {
    const st = MediaCardState(
      notificationsOn: true,
      channelImportance: 4,
      posted: false,
      notes: [MediaCardNote(id: 1124, channel: 'com.wyj.music.lyric_music.channel')],
    );
    expect(st.verdict(playing: true), MediaCardVerdict.postedElsewhere);
  });

  test('前台服务活着、通知却查不到，是手机拦的，不是没发', () {
    const st = MediaCardState(
      notificationsOn: true,
      channelImportance: 4,
      posted: false,
      serviceForeground: true,
    );
    expect(st.verdict(playing: true), MediaCardVerdict.hiddenByRom);
  });

  test('服务查不到时不许赖 ROM，仍按能重发的那种报', () {
    const unknown = MediaCardState(notificationsOn: true, channelImportance: 4, posted: false);
    expect(unknown.verdict(playing: true), MediaCardVerdict.notPosted);
    const asleep = MediaCardState(
      notificationsOn: true,
      channelImportance: 4,
      posted: false,
      serviceForeground: false,
    );
    expect(asleep.verdict(playing: true), MediaCardVerdict.notPosted);
  });

  test('取证那行把三份关键事实都带上', () {
    const st = MediaCardState(
      notificationsOn: true,
      channelImportance: 2,
      posted: false,
      serviceForeground: true,
      musicActive: true,
      notes: [MediaCardNote(id: 1124, channel: 'com.wyj.music.lyric_music.playback', foregroundService: true)],
      channels: ['playback:2', 'download:4'],
    );
    final line = st.detail;
    expect(line.contains('开关开'), true);
    expect(line.contains('通道2'), true);
    expect(line.contains('服务在'), true);
    expect(line.contains('1124@playback/FGS'), true);
    expect(line.contains('有栏[playback:2,download:4]'), true);
  });

  test('一栏都没有时，取证那行也要把这件事说出来', () {
    const st = MediaCardState(notificationsOn: true, posted: false);
    expect(st.detail.contains('通道-'), true);
    expect(st.detail.contains('有栏[无]'), true);
    // 桥那两样没补进来时不许凭空多出「桥里说」，免得看上去像查到了什么。
    expect(st.detail.contains('桥'), false);
  });

  test('连通道都没有时仍判「没贴上去」，闸门交给调用方按数据拿主意', () {
    const st = MediaCardState(notificationsOn: true, posted: false);
    expect(st.channelImportance, null);
    expect(st.verdict(playing: true), MediaCardVerdict.notPosted);
  });

  test('起没起过服务要说得出来：它分得开「没走到」和「走到一半断了」', () {
    const notStarted = MediaCardState(
      notificationsOn: true,
      posted: false,
      serviceForeground: false,
      serviceStarted: false,
    );
    expect(notStarted.detail.contains('服务不在·没起'), true);
    const started = MediaCardState(
      notificationsOn: true,
      posted: false,
      serviceForeground: false,
      serviceStarted: true,
    );
    expect(started.detail.contains('服务不在·起过'), true);
    // ROM 不答这一项时那一行不多嘴，别把「查不到」写成「没起」。
    const quiet = MediaCardState(notificationsOn: true, posted: false, serviceForeground: false);
    expect(quiet.detail.contains('服务不在·'), false);
  });

  test('我们这半截由播放层补进来，原生字段一个都不许丢', () {
    const st = MediaCardState(
      notificationsOn: true,
      channelImportance: 4,
      posted: false,
      serviceForeground: false,
      serviceStarted: true,
      musicActive: true,
      channels: ['playback:4'],
    );
    final merged = st.withBridge('=true/ready', 2, 'NullPointerException');
    expect(merged.channelImportance, 4);
    expect(merged.serviceStarted, true);
    expect(merged.musicActive, true);
    expect(merged.channels, ['playback:4']);
    expect(merged.bridgeErrors, 2);
    expect(merged.detail.contains('要播=true/ready'), true);
    expect(merged.detail.contains('桥错2·NullPointerException'), true);
  });

  test('桥一次都没错时不许凭空印出原文', () {
    const st = MediaCardState(notificationsOn: true, posted: false, musicActive: true);
    final line = st.withBridge('=true/ready', 0, null).detail;
    expect(line.contains('桥错'), false);
    expect(line.contains('NullPointerException'), false);
  });

  test('手机上那一行原样拼出来：一张截图就够定案', () {
    const st = MediaCardState(
      notificationsOn: true,
      posted: false,
      serviceForeground: false,
      serviceStarted: false,
      musicActive: true,
      // 卡上按钮按不动就是这一项：通知照发、歌照放，键全落在空处。
      listenerAlive: false,
    );
    expect(
      st.withBridge('=true/ready', 17, 'MissingPluginException(No implementation found)').detail,
      '开关开 通道- 服务不在·没起 出声开 挂着的通知[无] 有栏[无] 按键关 要播=true/ready '
      '桥错17·MissingPluginException(No implementation found)',
    );
  });
}
