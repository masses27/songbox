import '../engine/lx_engine.dart';
import '../models/song.dart';
import '../settings/app_settings.dart';
import 'bl_source.dart';
import 'kg_native.dart';
import 'kw_search.dart';
import 'tx_native.dart';
import 'tx_search.dart';
import 'wy_native.dart';
import 'wy_search.dart';

/// 一条自检结论。ok 决定绿勾还是感叹号，message 给人看，raw 留着服务器原话。
///
/// `warn` 是「这一行不通，但它本来就用不上」：音源脚本只覆盖酷我、酷狗被行为验证
/// 拦下都属于这类。跟「坏了」共用一个红色图标，她就会去修一个不需要修的东西。
typedef ProbeResult = ({String label, bool ok, bool warn, String message, String raw});

/// 手机端音源自检：网易云、QQ、音源脚本、酷狗概念版各问一次。
///
/// 每台网络出去看到的墙不一样——酷狗的行为验证按 IP 和频率弹，公司网拦得死、
/// 家里宽带未必拦；音源脚本的接口也有地区限流。电脑上测出来的结论搬不过去，
/// 所以这一页把每个源的原始回执摊在手机上，跑一次十几秒。
class SourceProbe {
  /// 各曲库都有这首歌，拿它当正向对照。
  static const keyword = '晴天';

  static Future<ProbeResult> netease() async {
    final quality = AppSettings.instance.quality;
    try {
      final found = await WySearch().search(keyword, limit: 10);
      if (found.list.isEmpty) {
        return _bad('网易云 端内直连', '搜索没有返回结果', 'total=${found.total}');
      }
      // 匿名搜出来的「晴天」大半是翻唱、深情版、AI 版，拿它们测出来的档位不算这首歌，
      // 所以先挑没括号的。可没括号的那几首又常常正是无版权下架的那批，所以跟 QQ 那行
      // 一样多试几首：谁先出链就报谁，而不是咬死第一首。
      final free = Song.preferOriginal(found.list.where((s) => s.fee != 1)).take(3).toList();
      final picks = free.isEmpty ? found.list.take(3).toList() : free;
      final tries = <String>[];
      Object? lastError;
      for (final pick in picks) {
        try {
          final url = await WyNative.resolveUrl(pick.songmid, quality: quality);
          return (
            label: '网易云 端内直连',
            ok: true, warn: false,
            message: '「${pick.name}」$quality 出链成功（全程匿名，会员歌靠 B 站整首）',
            raw: _tail(url),
          );
        } catch (e) {
          lastError = e;
          tries.add('${pick.songmid}「${pick.name}」：${_short(e)}');
        }
      }
      return _bad(
        '网易云 端内直连',
        '放不出：${_short(lastError)}',
        '已试：\n${tries.join('\n')}',
      );
    } catch (e) {
      return _bad('网易云 端内直连', '放不出：${_short(e)}', '$e');
    }
  }

  static Future<ProbeResult> tencent() async {
    final quality = AppSettings.instance.quality;
    try {
      final picks = await _txPicks();
      // payplay=1 的歌匿名一定回 104003，只拿没被标付费的那几首试；
      // 一首不行再试两首，这一行要量的是平台，不是某一首歌。
      Object? lastError;
      final tries = <String>[];
      final fromToplist = picks.via == '榜单';
      for (final pick in picks.songs) {
        try {
          final url = await TxNative.resolveUrl(pick.songmid, quality: quality);
          final tier = TxNative.tierOfUrl(url);
          return (
            label: 'QQ 端内直连',
            ok: true, warn: false,
            message: '「${pick.name}」出链成功，实际档位 $tier'
                '${fromToplist ? '（搜索没回话，这首是从榜单拿的）' : ''}'
                '${tier == '128k' && quality != '128k' ? '（匿名拿不到 $quality，已退回 128k）' : ''}',
            raw: _tail(url),
          );
        } catch (e) {
          lastError = e;
          tries.add('${pick.songmid}「${pick.name}」：${_short(e)}');
        }
      }
      // 归因码要留在短消息里：104003 是这首要会员，101404 是没这首，
      // 超时是被网络掐了——三种情况要做的事完全不一样，不能只写「放不出」。
      return _bad(
        'QQ 端内直连',
        '${picks.songs.length} 首免费歌都没出链：${_short(lastError)}',
        '已试：\n${tries.join('\n')}',
      );
    } catch (e) {
      return _bad('QQ 端内直连', '放不出：${_short(e)}', '$e');
    }
  }

  /// 弄一首能拿来试的 QQ 歌：先按关键词搜，搜索那两个域名都不回话就换榜单。
  ///
  /// 她手机上 `c.y.qq.com`/`c6.y.qq.com` 同时回 HTTP 500，而取链用的 `u.y.qq.com`
  /// 是通的（榜单就挂在同一个 `musicu.fcg` 上）。搜索不回话不等于腾讯不回话——
  /// 换到榜单这一行还能出链，说明要修的只是搜索那条链路；两路都死才是整个 QQ 不通。
  static Future<({List<Song> songs, String via})> _txPicks() async {
    Object? searchError;
    try {
      final found = await TxSearch().search(keyword, limit: 20);
      // 同名歌里 DJ 版、现场版常常就排在前面，而它们出的档位不能代表原版；
      // 先挑没括号的，试的还是同一首《晴天》。
      final free = Song.preferOriginal(found.list.where((s) => s.fee != 1)).take(3).toList();
      if (free.isNotEmpty) return (songs: free, via: '搜索');
      searchError = Exception('搜到的 ${found.total} 首全是会员歌');
    } catch (e) {
      searchError = e;
    }
    try {
      return (songs: await TxSearch.toplistSongs(), via: '榜单');
    } catch (e) {
      throw Exception('腾讯搜索和榜单都没给歌：${_short(searchError)}；${_short(e)}');
    }
  }

  /// 音源脚本那一层：网易云、QQ、B 站现在都走端内直连，脚本只是给酷我这类
  /// 别的入口覆盖不到的曲库兜底。
  ///
  /// 关键是把「不通」和「用不上」分开说：市面上的脚本九成只覆盖 kw，而 kw 的取链
  /// 接口已经下线（只剩 11 秒试听），这种失败换网络、换脚本都不会变好。要是这一行
  /// 跟「放不出」共用一个红色图标，她就会去修一个本来不需要修的东西。
  static Future<ProbeResult> lxSource() async {
    final engine = LxEngine.active;
    final support = engine?.support;
    final sources = support?.sources.join(' / ') ?? '未上报';
    // 只有脚本自己上报了覆盖、且覆盖里除了酷我什么都没有时，才敢说这一层用不上。
    // 没上报（support 为 null 或列表为空）是另一回事：那是不知道，不是没用。
    final covered = support?.sources ?? const <String>[];
    final inert = covered.isNotEmpty && covered.every((s) => s == 'kw');
    if (engine == null || !engine.inited) {
      return _bad(
        '音源脚本',
        '没启用。只听网易云、QQ、B 站用不上这一层，不用管',
        engine?.initError ?? '未启用',
        warn: true,
      );
    }
    try {
      final found = await KwSearch().search(keyword, limit: 5);
      if (found.list.isEmpty) {
        return _bad('音源脚本', '酷我搜索没有结果', '覆盖：$sources', warn: inert);
      }
      final pick = found.list.first;
      final result = await engine.sendRequest('kw', 'musicUrl', pick.toMusicInfo(),
          timeout: const Duration(seconds: 15));
      final data = result['data'];
      final url = data is Map ? data['url'] : data;
      if (url is String && url.isNotEmpty) {
        return (
          label: '音源脚本',
          ok: true, warn: false,
          message: '「${pick.name}」酷我取链成功，脚本覆盖 $sources 个平台',
          raw: _tail(url),
        );
      }
      return _bad('音源脚本', '脚本回了话，但没给地址', _tail('${data ?? result}'), warn: inert);
    } catch (e) {
      return _bad(
        '音源脚本',
        inert
            ? '这个脚本只覆盖酷我，而酷我那条取链接口已经废了 —— '
                '现在听歌走的是端内直连和 B 站，这一行不用管'
            : '脚本取链失败（覆盖：$sources）：${_short(e)}',
        '$e',
        warn: inert,
      );
    }
  }

  /// B 站那一档：会员墙后面唯一还肯匿名给整首的源，所以它自己占一行。
  ///
  /// 这一行量的是「这台机子上 B 站能不能搜到、能不能出链」，对照曲用《晴天》——
  /// 它在网易云是要会员的那一首，正是这条路要救的那种歌。269 秒是网易云那首的时长，
  /// 拿来挡掉「43 分钟单曲循环」这类合集。
  static Future<ProbeResult> bilibili() async {
    try {
      final picks = await BlSource.findTwins(keyword, '周杰伦', wantSec: 269);
      if (picks.isEmpty) {
        return _bad('B 站 整首兜底', '搜到了片子，但没有一条同时对上曲名、歌手和时长', '关键词：$keyword 周杰伦');
      }
      final pick = picks.first;
      final url = await BlSource.resolveUrl(pick.songmid);
      return (
        label: 'B 站 整首兜底',
        ok: true, warn: false,
        message: '「${pick.name}」出链成功，档位 ${BlSource.tierOfUrl(url)}（匿名上限 192k，整首）',
        raw: _tail(url),
      );
    } catch (e) {
      return _bad('B 站 整首兜底', '放不出：${_short(e)}', '$e');
    }
  }

  /// 酷狗概念版：注册设备 → 搜索 → 取链，把每一步的码都留下。
  /// 关心的是取链那一步会不会回 `20028 本次请求需要验证`。
  static Future<ProbeResult> kugou() async {
    KgNative.resetDevice();
    try {
      final found = await KgNative.search(keyword);
      if (found.isEmpty) return _bad('酷狗 概念版', '搜索没有返回结果', '曲库接口这次没答话');
      final pick = found.firstWhere((s) => s.pay == 0, orElse: () => found.first);
      final reg = await KgNative.register();
      final probe = await KgNative.probeUrl(pick.hash);
      final raw = '注册 HTTP ${reg.http} ${_tail(reg.raw, 120)}\n取链 HTTP ${probe.http} ${_tail(probe.raw, 160)}'
          '${probe.ssaCode == null ? '' : '\nssa-code ${probe.ssaCode}'}';
      if (probe.url != null && probe.url!.isNotEmpty) {
        return (
          label: '酷狗 概念版',
          ok: true,
          warn: false,
          message: '「${pick.name}」出链成功',
          raw: raw,
        );
      }
      final gate = probe.code == 20028 || probe.code == 30020;
      // 酷狗这条最后没接进播放（取链一律被行为验证拦下，见结案记录），所以这一行
      // 只是留个测量值：不通是她没法修、也不需要修的事。
      return _bad(
        '酷狗 概念版',
        gate
            ? '搜索、注册都通，取链被行为验证拦下（errcode ${probe.code}）；'
                '这一家本来就没接进播放，不用管'
            : '取链没成功（errcode ${probe.code ?? '未知'}）；这一家本来就没接进播放，不用管',
        raw,
        warn: true,
      );
    } catch (e) {
      return _bad('酷狗 概念版', '请求没发出去：${_short(e)}', '$e');
    }
  }

  static ProbeResult _bad(String label, String message, String raw, {bool warn = false}) =>
      (label: label, ok: false, warn: warn, message: message, raw: raw);

  /// 红字那一行要能被截图看清：压平换行、掐掉 DioException 的长堆栈。
  /// 异常留头（类型在前），所以不复用只留尾巴的 _tail。
  static String _short(Object? e) {
    final one = '$e'.replaceAll('\n', ' ');
    return one.length <= 70 ? one : '${one.substring(0, 70)}…';
  }

  /// 长地址截个尾巴就够看了，整串摊在小屏上没有意义。
  static String _tail(String s, [int max = 90]) {
    final one = s.replaceAll('\n', ' ');
    return one.length <= max ? one : '…${one.substring(one.length - max)}';
  }
}
