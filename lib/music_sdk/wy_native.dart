import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' as pc;

import '../models/results.dart';

/// NetEase (wy) playback + lyric, computed entirely on-device.
///
/// NetEase guards `weapi` endpoints by AES-encrypting the request body twice
/// with constants baked into its own web player. Re-implementing that here is
/// what removes the need for any third-party bridge service.
class WyNative {
  static const _outerKey = '0CoJUm6Qyw8W8jud';

  /// Inner key; `_encSecKey` is this key RSA-locked by NetEase's public key,
  /// so the two must stay paired.
  static const _innerKey = 'B3v3kH4vRPWRJFfH';
  static const _iv = '0102030405060708';
  static const _encSecKey =
      '85302b818aea19b68db899c25dac229412d9bba9b3fcfe4f714dc016bc1686fc446a08844b1f8327fd9cb623cc189be00c5a365ac835e93d4858ee66f43fdc59e32aaed3ef24f0675d70172ef688d376a4807228c55583fe5bac647d10ecef15220feef61477c28cae8406f6f9896ed329d6db9f88757e31848a6c2ce2f94308';

  static const _bitRates = {'128k': 128000, '320k': 320000, 'flac': 999000};

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.plain,
    validateStatus: (s) => true,
    headers: const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      'Referer': 'https://music.163.com/',
    },
  ));

  /// Returns a directly playable mp3 url, or throws for VIP-only tracks.
  /// 会员歌在匿名请求下回 `code: -110`（实测：`url:null`、`freeTrialInfo:null`、
  /// `payed:0`）——网易云这一层不再放会员曲目，整首由 B 站、酷狗那两档兜。
  static Future<String> resolveUrl(String id, {String quality = '320k'}) async {
    final body = await weapi({
      'ids': [id],
      'br': _bitRates[quality] ?? 320000,
    }, '/weapi/song/enhance/player/url');
    final data = body['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first as Map;
      final url = first['url'];
      if (url is String && url.isNotEmpty) return url;
      if ((first['code'] as num?)?.toInt() == -110) throw Exception('VIP 专属：网易云这首要会员');
    }
    throw Exception('这首歌是网易云 VIP 专属');
  }

  /// `tv: -1` asks NetEase for the translation track as well; songs without one
  /// leave `tlyric.lyric` empty. Verified against the live endpoint: the payload
  /// is `lrc` / `tlyric` / `romalrc`, each holding its text under `lyric`.
  static Future<LyricResult> resolveLyric(String id) async {
    try {
      final body = await weapi({
        'id': id,
        'tv': -1,
        'lv': -1,
        'rv': -1,
        'kv': -1,
      }, '/weapi/song/lyric');
      return LyricResult(
        lyric: (body['lrc'] as Map?)?['lyric'] as String? ?? '',
        tlyric: (body['tlyric'] as Map?)?['lyric'] as String?,
      );
    } catch (_) {
      return LyricResult(lyric: '');
    }
  }

  /// Catalog endpoints that need no signing (playlist lists, detail).
  static Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query}) async {
    final resp = await _dio.get('https://music.163.com$path', queryParameters: query);
    final raw = resp.data;
    if (raw is String) {
      try {
        final body = jsonDecode(raw);
        if (body is Map) return Map<String, dynamic>.from(body);
      } catch (_) {}
    }
    throw Exception('网易云接口返回异常（HTTP ${resp.statusCode}）');
  }

  /// 端内那套 `weapi` 签名：payload 用内外两层 AES 各加密一次，`encSecKey` 是固定的
  /// 公钥产物（本机算好写死）。全程匿名，`csrf_token` 留空——没有登录态就没有跨站校验的对象。
  static Future<Map<String, dynamic>> weapi(Map<String, dynamic> payload, String path) async {
    var params = _aesCbcBase64(jsonEncode(payload), _outerKey);
    params = _aesCbcBase64(params, _innerKey);
    final resp = await _dio.post(
      'https://music.163.com$path?csrf_token=',
      data: {'params': params, 'encSecKey': _encSecKey},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final raw = resp.data;
    if (raw is String) {
      try {
        final body = jsonDecode(raw);
        if (body is Map) return Map<String, dynamic>.from(body);
      } catch (_) {}
    }
    throw Exception('网易云接口返回异常（HTTP ${resp.statusCode}）');
  }

  static String _aesCbcBase64(String data, String key) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine())
      ..init(
        true,
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(Uint8List.fromList(utf8.encode(key))),
          Uint8List.fromList(utf8.encode(_iv)),
        ),
      );
    final input = _pkcs7Pad(utf8.encode(data));
    final out = Uint8List(input.length);
    for (var off = 0; off < input.length; off += 16) {
      cipher.processBlock(input, off, out, off);
    }
    return base64.encode(out);
  }

  static Uint8List _pkcs7Pad(List<int> data) {
    final pad = 16 - (data.length % 16);
    return Uint8List.fromList([...data, ...List<int>.filled(pad, pad)]);
  }
}
