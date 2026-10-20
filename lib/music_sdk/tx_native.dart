import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../settings/app_settings.dart';
import '../util/json_body.dart';

/// QQ Music (tx) playback + lyric, computed on-device.
///
/// 取链走 `musicu.fcg` 的 `vkey.GetVkeyServer`：给它 mid 和想要的文件名，它回一条
/// 带签名的 `purl`，拼上 `sip` 里的任意一个域名就是完整地址。
///
/// 匿名只有一个档位（128k）：`M800`、`RS01` 都要会员登录态才给，这个 App 全程不带
/// 凭证，所以高档一律拿不到——需要更高音质时去别的源找同一首，别在这儿降档重试。
class TxNative {
  /// 音质 -> 文件名（前缀 + 容器）。实测匿名只有 `M500`(128k) 给整首：`M800`(320k)
  /// 和 `RS01`/`F000`(flac) 一律回 `result:104003`、`purl` 为空。
  /// flac 的容器必须是 `.flac`，用 `.mp3` 结尾问它就不算真的在问无损。
  static const _tiers = {
    '128k': ('M500', 'mp3'),
    '320k': ('M800', 'mp3'),
    'flac': ('RS01', 'flac'),
  };

  /// 免费账号唯一稳拿的档位，高档撞墙后马上退回到它。
  static const _freeQuality = '128k';

  /// 被会员墙挡住时腾讯回的错误码（实测）。
  static const _blocked = 104003;

  /// 整条请求被网关判成无效询问（实测 `msg` 是 `<IP>;invalidq;`、`sip` 直接回空）。
  /// 本机连着问几十次就撞上过——这是频率限制，不是这首歌要会员。
  static const _invalidQuery = 104009;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    validateStatus: (s) => true,
    headers: const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      'Referer': 'https://y.qq.com/portal/player.html',
    },
  ));

  /// 拿到一条能直接播的整首地址；要会员的歌抛异常，由调用方继续往下换源。
  static Future<String> resolveUrl(String songmid, {String quality = '128k'}) async {
    final q = _tiers.containsKey(quality) ? quality : _freeQuality;
    var r = await _ask(songmid, q);
    // 匿名身份只有 128k 这一档能出整首，而全局音质常常设在 320k/无损。
    // 撞墙就当场退回 M500 再问一次：换源那条链子每个候选只给两次机会，
    // 不在这里退档等于整条 QQ 救场都白白丢掉。
    if (r.url == null && q != _freeQuality) r = await _ask(songmid, _freeQuality);
    if (r.url != null) return r.url!;
    if (r.result == _blocked) throw Exception('腾讯这首也要会员');
    if (r.result == _invalidQuery) {
      throw Exception('腾讯把这次请求判成无效了（104009，多半是问得太频繁），过一会儿再试');
    }
    throw Exception('腾讯没返回播放链接（${r.result ?? '没给归因码'}）');
  }

  /// 地址里带着文件名，能认出实际拿到的是哪一档。
  static String tierOfUrl(String url) => url.contains('M500')
      ? '128k'
      : url.contains('M800')
          ? '320k'
          : url.contains('RS01') || url.contains('Q000') || url.contains('F000')
              ? 'flac'
              : '未知';

  /// 问一次取链接口：拿到完整地址就填 url，拿不到就带回归因码。
  static Future<({String? url, int? result})> _ask(String songmid, String quality) async {
    final t = _tiers[quality]!;
    final filename = '${t.$1}$songmid.${t.$2}';
    final body = {
      'comm': {'ct': 24, 'cv': 0},
      'req_0': {
        'module': 'vkey.GetVkeyServer',
        'method': 'CgiGetVkey',
        'param': {
          // 设备号：本机第一次取链时生成、之后一直用这一个。腾讯只要求它是个 10 位
          // 数字串，但所有客户端共用一个号（早先就是 '10000'）是风控最好归并的特征。
          'guid': AppSettings.instance.ensureTxGuid(),
          'songmid': [songmid],
          'songtype': [0],
          // 全程游客：uin '0'、不带 cookie。腾讯按这个身份只开 M500（128k），
          // 320k/无损要会员账号给的登录态，这条路已经不走了。
          'uin': '0',
          'loginflag': 1,
          'platform': '20',
          'filename': [filename],
        }
      }
    };
    final resp = await _dio.get('https://u.y.qq.com/cgi-bin/musicu.fcg',
        queryParameters: {'format': 'json', 'data': jsonEncode(body)},
        options: Options(responseType: ResponseType.plain));
    final raw = resp.data;
    if (raw is! String) throw Exception('腾讯取链接口返回异常（HTTP ${resp.statusCode}）');
    final j = decodeBody(raw, status: resp.statusCode, label: '腾讯取链接口');
    final data = (((j as Map?)?['req_0'] as Map?)?['data'] as Map?) ?? const {};
    final info = ((data['midurlinfo'] as List?)?.firstOrNull as Map?) ?? const {};
    final purl = '${info['purl'] ?? ''}';
    if (purl.isNotEmpty) {
      final sip = ((data['sip'] as List?) ?? const []).map((e) => '$e').toList();
      // `purl` 只是半截路径，域名在 `sip` 里；`sip` 回空等于这档没拿到，
      // 别把拼不出一首歌的半截地址交出去。
      if (sip.isNotEmpty) return (url: '${sip.first}$purl', result: null);
    }
    // `result` 是这首歌的归因码，`retcode` 是这一次请求的归因码。整条请求被网关掐掉时
    //（104009）`result` 照旧回 0，只看它等于把「问得太频繁」报成「没给归因码」。
    final songCode = (info['result'] as num?)?.toInt() ?? 0;
    final requestCode = (data['retcode'] as num?)?.toInt() ?? 0;
    final code = songCode != 0 ? songCode : requestCode;
    return (url: null, result: code == 0 ? null : code);
  }

  /// 歌词。接口把正文放在 base64 里（实测 `lyric` 开头是 `W3RpO`），翻译在 `trans`。
  static Future<LyricResult> resolveLyric(String songmid) async {
    try {
      final resp = await _dio
          .get('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg', queryParameters: {
        'songmid': songmid,
        'format': 'json',
        'n': 1,
        'g_tk': 5381,
        'loginUin': '0',
        'hostUin': '0',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': 0,
        'platform': 'yqq.json',
        'needNewCode': 0,
      });
      final raw = resp.data;
      if (raw is! String) return LyricResult(lyric: '');
      final j = decodeBody(raw, status: resp.statusCode, label: '腾讯歌词接口');
      if (j is! Map) return LyricResult(lyric: '');
      final trans = _unb64(j['trans']);
      return LyricResult(
        lyric: _unb64(j['lyric']),
        tlyric: trans.isEmpty ? null : trans,
      );
    } catch (_) {
      return LyricResult(lyric: '');
    }
  }

  static String _unb64(Object? v) {
    final s = '${v ?? ''}';
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64Decode(s));
    } catch (_) {
      // 偶尔就是明文回来，别把整首歌词丢掉。
      return s;
    }
  }
}
