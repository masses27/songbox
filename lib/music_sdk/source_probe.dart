import '../models/song.dart';
import '../settings/app_settings.dart';
import 'bl_source.dart';
import 'kg_native.dart';
import 'tx_native.dart';
import 'tx_search.dart';
import 'wy_native.dart';
import 'wy_search.dart';

/// 一条自检结论。ok 决定绿勾还是感叹号，message 给人看，raw 留着服务器原话。
///
/// `warn` 是「这一行不通，但它本来就用不上」：对照曲本身在酷狗也是付费的、
/// 搜索通了可直链就是不给这一首，都属于这类。跟「坏了」共用一个红色图标，
/// 她就会去修一个不需要修的东西。
typedef ProbeResult = ({String label, bool ok, bool warn, String message, String raw});

/// 手机端曲库自检：网易云、QQ、B 站、酷狗各问一次。
///
/// 每台网络出去看到的墙不一样——酷狗的行为验证按 IP 和频率弹（那条老通道现在不参与播放，
/// 只留个测量值）。电脑上测出来的结论搬不过去，所以这一页把每个源的原始回执摊在手机上，
/// 跑一次十几秒。
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
            message: '「${pick.name}」${qualityLabel(quality)} 出链成功'
                '（全程匿名，会员歌靠 B 站、酷狗整首）',
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
            message: '「${pick.name}」出链成功，实际档位 ${qualityLabel(tier)}'
                '${fromToplist ? '（搜索没回话，这首是从榜单拿的）' : ''}'
                '${tier == '128k' && quality != '128k' ? '（匿名拿不到 ${qualityLabel(quality)}）' : ''}',
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

  /// B 站那一档：会员墙后面第一条匿名整首路（192k），所以它自己占一行。
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

  /// 酷狗那一行：0.8.26 起它是会员墙后面的第二条整首路（匿名 128k），所以量的是
  /// 播放真正走的那条 `trackercdn` 直链，而不是当年结案用的 `v5/url`。
  ///
  /// 旧通道不参与播放，但「这台机子、这个出口到底拦不拦」只有她手机上测得出来，
  /// 所以顺手量一行留在原始回执里当证据，不影响绿勾。
  static Future<ProbeResult> kugou() async {
    const label = '酷狗 整首直链';
    KgNative.resetDevice();
    try {
      final found = await KgNative.search(keyword, limit: 10);
      if (found.isEmpty) return _bad(label, '搜索没有返回结果', '曲库接口这次没答话');
      // Privilege>=10 的在酷狗也要会员，匿名直链一定回 status:2，拿它测不出平台通不通。
      final free = found.where((s) => s.priv < 10).take(2).toList();
      if (free.isEmpty) {
        return _bad(
          label,
          '搜到 ${found.length} 条，全都标着要会员（Privilege>=10）：这一首看不出平台通不通',
          '关键词：$keyword',
          warn: true,
        );
      }
      final tries = <String>[];
      ({String name, KgReply reply})? hit;
      for (final pick in free) {
        final r = await KgNative.probeDirect(pick.hash);
        tries.add('「${pick.name}」HTTP ${r.http} status=${r.status ?? '-'} ${r.error}');
        // 出一条就够了：这一行看的是「这条路通不通」，第二次问同一接口只是把
        // 出口 IP 的额度再花掉一遍（整单体检并发的时候尤其经不起）。
        if (r.url != null && r.url!.isNotEmpty) {
          hit = (name: pick.name, reply: r);
          break;
        }
      }
      final legacy = await _kgLegacy(free.first.hash);
      if (hit != null) {
        final r = hit.reply;
        final mb = r.fileSize == null ? '' : ' · ${(r.fileSize! / 1048576).toStringAsFixed(1)} MB';
        return (
          label: label,
          ok: true,
          warn: false,
          message: '「${hit.name}」出链成功，${r.bitRate == null ? '128k' : '${r.bitRate! ~/ 1000}k'}'
              '$mb（匿名整首，上限 128k）',
          raw: '${tries.join('\n')}\n${_tail(hit.reply.url ?? '', 120)}\n$legacy',
        );
      }
      // status:2 = 直链答了话、只是这首不给免费整首；那是对照曲的问题，不是这条路坏了。
      final paid = tries.any((t) => t.contains('status=2'));
      return _bad(
        label,
        paid
            ? '搜索、直链都通，可标着免费的那几首其实也要会员（status:2）：换个网络再跑一次看看'
            : '搜索通，直链没给地址：${tries.join(' / ')}',
        '已试：\n${tries.join('\n')}\n$legacy',
        warn: paid,
      );
    } catch (e) {
      return _bad(label, '请求没发出去：${_short(e)}', '$e');
    }
  }

  /// 旧通道（注册设备 → `v5/url`）量一行结论。`errcode 20028` 就是要行为验证。
  static Future<String> _kgLegacy(String hash) async {
    try {
      final reg = await KgNative.register();
      final probe = await KgNative.probeUrl(hash);
      final gate = probe.code == 20028 || probe.code == 30020
          ? '要行为验证'
          : 'errcode ${probe.code ?? '未知'}';
      return '旧通道 v5/url（不参与播放）：注册 HTTP ${reg.http}，取链 HTTP ${probe.http} $gate'
          '${probe.ssaCode == null ? '' : ' ssa-code ${probe.ssaCode}'}';
    } catch (e) {
      return '旧通道 v5/url（不参与播放）：没跑起来 ${_short(e)}';
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
