import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:pointycastle/asymmetric/api.dart' as pca;

import '../models/song.dart';

/// 酷狗一次请求的原始回执：HTTP 码、业务码、验证标识、拿到的播放地址、响应原文。
/// 自检页要的是「服务器到底回了什么」，所以这里一律不翻译成人话。
typedef KgReply = ({
  int http,
  int? code,
  int? status,
  String error,
  String? ssaCode,
  String? url,
  int? bitRate,
  int? fileSize,
  String ext,
  String raw,
});

/// 酷狗概念版（appid 3116）端内直连：匿名设备注册 + 歌曲取链。
///
/// 这里有两套取链，走的门不一样：
/// - [probeUrl] 打 `gateway.kugou.com/v5/url`，要注册设备、要 signature。办公网上每次
///   都回 `errcode 20028 本次请求需要验证`（响应头带 `ssa-code: gz_tx_event_…`），那是
///   酷狗的行为验证，要 App 里那段 WASM 滑块才能过。它按 IP 和频率决定弹不弹，家里宽带
///   和蜂窝上未必弹——这个只能在手机上跑一次。
/// - [resolveUrl] 打 `trackercdn.kugou.com/i/v2`，不注册、不签名、不要 cookie，
///   key 只是 md5(哈希 + 'kgcloudv2')。**这一条 0.8.26 接进了播放**，见下面注释。
class KgNative {
  static const _appid = 3116;
  static const _clientver = 11440;
  static const _salt = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
  static const _keySalt = '185672dd44712f60bb1736df5a377e82';
  static const _pageId = 967177915;
  static const _ppageId = '356753938,823673182,967485191';

  /// 概念版 RSA 公钥（SPKI，base64），注册时锁住那次请求用到的 AES 随机 key。
  static const _rsaKey =
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5sy'
      'ug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJD'
      'Nr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB';

  static const _ua = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    validateStatus: (s) => true,
  ));

  /// 设备身份。酷狗按 mid/dfid 记账，所以每跑一次自检都换一副新号，
  /// 免得上一轮被拦的记录把这一轮也带进验证里。
  static String _mid = _newMid();
  static String _dfid = _newDfid();

  static void resetDevice() {
    _mid = _newMid();
    _dfid = _newDfid();
  }

  /// 匿名设备注册。成功时 `status:1`、`data.dfid` 是服务器发下来的会话号，取链要复用。
  static Future<KgReply> register() async {
    final guid = _randomHex(32);
    final aesKey = _randomHex(6);
    final profile = jsonEncode({
      'availableRamSize': 4983533568,
      'availableRomSize': 48114719,
      'availableSDSize': 48114717,
      'basebandVer': '',
      'batteryLevel': 100,
      'batteryStatus': 3,
      'brand': 'Redmi',
      'buildSerial': 'unknown',
      'device': 'marble',
      'imei': guid,
      'imsi': '',
      'manufacturer': 'Xiaomi',
      'uuid': guid,
      'accelerometer': false,
      'accelerometerValue': '',
      'gravity': false,
      'gravityValue': '',
      'gyroscope': false,
      'gyroscopeValue': '',
      'light': false,
      'lightValue': '',
      'magnetic': false,
      'magneticValue': '',
      'orientation': false,
      'orientationValue': '',
      'pressure': false,
      'pressureValue': '',
      'step_counter': false,
      'step_counterValue': '',
      'temperature': false,
      'temperatureValue': '',
    });
    final body = _aesEncrypt(profile, aesKey);
    final params = <String, dynamic>{
      'dfid': _dfid,
      'mid': _mid,
      'uuid': '-',
      'appid': _appid,
      'clientver': _clientver,
      'clienttime': _now(),
      'part': 1,
      'platid': 1,
      // 锁好的那把一次性 AES key：服务器解开它才知道用哪把钥匙解请求体和回执。
      'p': _rsaEncrypt(jsonEncode({'aes': aesKey, 'uid': 0, 'token': ''})),
    };
    params['signature'] = _sign(params, body);
    final resp = await _dio.post(
      'https://userservice.kugou.com/risk/v2/r_register_dev',
      queryParameters: params.map((k, v) => MapEntry(k, '$v')),
      data: body,
      // 回执是一整块 AES 密文，按文本读会先把字节当成 UTF-8 解码坏掉。
      options: Options(
        headers: _headers('userservice.kugou.com'),
        contentType: 'text/plain',
        responseType: ResponseType.bytes,
      ),
    );
    final json = _decryptReply(resp, aesKey);
    final data = json.json['data'];
    if (data is Map && data['dfid'] != null) _dfid = '${data['dfid']}';
    return _reply(resp, json.json, raw: json.plain);
  }

  /// 匿名搜索（`songsearch.kugou.com`）：这条一直通，被拦的只是 v5/url 那一步。
  ///
  /// `priv` 取的是搜索结果的 `Privilege`（付费判断见 [isPaid]），`sec` 是时长——
  /// 拿它对上「是不是同一首歌」，也挡掉那些几十分钟的合集。
  static Future<List<({String name, String singer, String hash, int priv, int sec})>> search(
    String keyword, {
    int limit = 8,
  }) async {
    final resp = await _dio.get('https://songsearch.kugou.com/song_search_v2', queryParameters: {
      'keyword': keyword,
      'platform': 'AndroidFilter',
      'iscorrection': '1',
      'hifiquality': '0',
      'pagesize': '$limit',
      'PrivilegeFilter': '0',
      'page': '1',
    }, options: Options(headers: {'User-Agent': _ua}));
    final lists = _plainJson(resp)['data'];
    final items = lists is Map ? lists['lists'] : null;
    if (items is! List) return const [];
    final out = <({String name, String singer, String hash, int priv, int sec})>[];
    for (final e in items.whereType<Map>()) {
      final hash = '${e['FileHash'] ?? ''}';
      if (hash.isEmpty) continue;
      final singers = (e['Singers'] as List?)?.map((s) => '${(s as Map)['name']}').join('、') ?? '';
      out.add((
        name: '${e['OriSongName'] ?? e['SongName'] ?? ''}',
        singer: singers,
        hash: hash,
        priv: _int(e['Privilege']) ?? 0,
        sec: _int(e['Duration']) ?? 0,
      ));
    }
    return out;
  }

  /// 搜索结果里的付费标记。`Privilege>=10` 就是要会员：抽样九条候选零例外
  /// （0 和 8 的匿名直链给整首，10 的一律回 `status:2`）。
  /// 这个数比 `PayMask` 可靠——后者在这套查询参数下根本不回，以前解析出来的永远是 0。
  static bool isPaid(int priv) => priv >= 10;

  /// 搜索结果换成队列里用得上的 [Song]：哈希放 `songmid`（取链就认它），
  /// `Privilege>=10` 写成 `fee:1`，让 [Song.twinBlocked] 那道关在挑候选时就把会员歌筛掉。
  static Future<List<Song>> searchSongs(String keyword, {int limit = 8}) async =>
      (await search(keyword, limit: limit))
          .map((e) => Song(
                source: 'kg',
                songmid: e.hash,
                name: e.name,
                singer: e.singer,
                interval: e.sec > 0 ? e.sec : null,
                fee: isPaid(e.priv) ? 1 : 0,
              ))
          .toList();

  /// 匿名整首直链的取链地址。
  ///
  /// key 只有一条规则：md5(哈希 + 'kgcloudv2')，**哈希用哪一串写进 url，就签哪一串**。
  /// 全大写、全小写都回 `status:1`，一大写一小写回 `status:0 Bad key`——所以这里固定转大写，
  /// 免得调用方传了小写哈希、又拿小写去签，看着「搜索明明通、取链就是不给」。
  static const _directSalt = 'kgcloudv2';

  static String directApiUrl(String hash) {
    final h = hash.toUpperCase();
    return 'https://trackercdn.kugou.com/i/v2/?appid=1005&pid=2&cmd=25&behavior=play'
        '&hash=$h&key=${_md5('$h$_directSalt')}';
  }

  /// 直链取链的原始回执，给自检页摆证据用：`status`、`bitRate`、`fileSize` 都是从这次请求读的。
  static Future<KgReply> probeDirect(String hash) async {
    final resp = await _dio.get(directApiUrl(hash), options: Options(headers: {'User-Agent': _ua}));
    final json = _plainJson(resp);
    final urls = (json['url'] as List?)?.whereType<String>().where((u) => u.isNotEmpty).toList() ??
        const <String>[];
    return _reply(resp, json, url: urls.isEmpty ? null : urls.first);
  }

  /// 播放要的那条整首 mp3 地址。
  static Future<String> resolveUrl(String hash) async => urlOrExplain(await probeDirect(hash));

  /// 直链回执拆成「地址」或者一句说清为什么没有地址。单独抽出来是让单测能钉住归因——
  /// 这几种失败在她那边是三条不同的路：要会员→换版本，返回异常→过会儿再试，
  /// `Bad key`→是我们签错了串。归因错了，代价是白等或者错打七天的标记。
  static String urlOrExplain(KgReply reply) {
    final url = reply.url;
    if (url != null && url.isNotEmpty) return url;
    // 没有 status = 答的不是那个 JSON（风控页、空 body、网关直接拦回）。这首歌有没有版权
    // 跟这一下没关系，所以说成「返回异常」让换源链子把它算进 flaky：
    // 不然一次拦截就打成「这首确认没有免费版」，标记一落就是七天。
    if (reply.status == null) throw Exception('酷狗直链返回异常（HTTP ${reply.http}）');
    if (reply.status == 2) throw Exception('酷狗这首也要会员（status:2）');
    if (reply.status == 0) throw Exception(reply.error.isEmpty ? '酷狗不认这个 key' : reply.error);
    throw Exception('酷狗没给地址（status ${reply.status}）');
  }

  /// v5/url 那条（要注册、要签名、要过行为验证）——0.8.26 之后它不再参与播放，
  /// 只留给自检页量一次「这台机、这个出口，酷狗到底弹不弹验证」。`code:20028`＝要行为验证。
  static Future<KgReply> probeUrl(String hash, {String quality = '128'}) async {
    final h = hash.toLowerCase();
    final params = <String, dynamic>{
      'dfid': _dfid,
      'mid': _mid,
      'uuid': '-',
      'appid': _appid,
      'clientver': _clientver,
      'clienttime': _now(),
      'hash': h,
      'album_id': 0,
      'album_audio_id': 0,
      'quality': quality,
      'area_code': 1,
      'ssa_flag': 'is_fromtrack',
      'version': _clientver,
      'page_id': _pageId,
      'behavior': 'play',
      'pid': 411,
      'cmd': 26,
      'pidversion': 3001,
      'IsFreePart': 0,
      'ppage_id': _ppageId,
      'cdnBackup': 1,
      'module': '',
      // 每首歌一个 key：md5(哈希 + keySalt + appid + mid + userid)，userid 匿名就是 0。
      'key': _md5('$h$_keySalt$_appid${_mid}0'),
    };
    // 实测过上游 KuGouMusicApi 的写法：它 song_url 里写的 `notSign: true` 其实打不中
    // createRequest 的判断（那边读的是 `notSignature`），所以它照样发 signature —— 我们照旧的
    // 参数集就是对的。换成不发 signature 只会拿到 20006「err signature」，换 clientver 11430
    // 也一样；这一层的门不在参数上，在 v5/url 的行为风控上（见类注释）。
    params['signature'] = _sign(params);
    final resp = await _dio.get(
      'https://gateway.kugou.com/v5/url',
      queryParameters: params.map((k, v) => MapEntry(k, '$v')),
      options: Options(headers: _headers('trackercdn.kugou.com')),
    );
    final json = _plainJson(resp);
    var data = json['data'];
    if (data is! Map) data = json;
    final urlField = data['url'];
    final url = urlField is List
        ? (urlField.isEmpty ? null : '${urlField.first}')
        : urlField is String && urlField.isNotEmpty
            ? urlField
            : null;
    return _reply(resp, json, url: url);
  }

  static Map<String, String> _headers(String router) => {
        'User-Agent': _ua,
        'Accept': 'application/json, text/plain, */*',
        'dfid': _dfid,
        'mid': _mid,
        'clienttime': '${_now()}',
        'kg-rc': '1',
        'kg-thash': '5d816a0',
        'kg-rec': '1',
        'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
        'x-router': router,
      };

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// md5(盐 + 按 key 排好的 k=v 拼串 + 请求体 + 盐)。GET 没有请求体，那一段是空串。
  static String _sign(Map<String, dynamic> params, [String body = '']) {
    final keys = params.keys.toList()..sort();
    final joined = keys.map((k) => '$k=${params[k]}').join();
    return _md5('$_salt$joined$body$_salt');
  }

  static KgReply _reply(Response<dynamic> resp, Map<String, dynamic> json,
      {String? url, String? raw}) {
    final text = raw ?? '${resp.data ?? ''}';
    return (
      http: resp.statusCode ?? 0,
      code: _int(json['errcode'] ?? json['error_code']),
      status: _int(json['status']),
      error: '${json['error'] ?? json['error_msg'] ?? ''}',
      ssaCode: resp.headers.value('ssa-code'),
      url: url,
      bitRate: _int(json['bitRate']),
      fileSize: _int(json['fileSize']),
      ext: '${json['extName'] ?? ''}',
      raw: text.length > 240 ? '${text.substring(0, 240)}…' : text,
    );
  }

  static Map<String, dynamic> _plainJson(Response<dynamic> resp) {
    final raw = '${resp.data ?? ''}'.trim();
    for (final candidate in [raw, _stripTags(raw)]) {
      try {
        final j = jsonDecode(candidate);
        if (j is Map) return Map<String, dynamic>.from(j);
      } catch (_) {}
    }
    return {};
  }

  /// 注册接口的回执是一整块 AES 密文，用这次请求发出去的那把 key 解回来。
  /// 解不开就是网关直接拦回的明文，原样留着给自检页看。
  static ({Map<String, dynamic> json, String plain}) _decryptReply(
      Response<dynamic> resp, String aesKey) {
    final data = resp.data;
    final bytes = data is List<int>
        ? data
        : data is String
            ? _tryBase64(data.trim())
            : null;
    if (bytes == null) return (json: const {}, plain: '${data ?? ''}');
    try {
      final plain = _aesDecryptBytes(bytes, aesKey);
      final j = jsonDecode(plain);
      return (json: j is Map ? Map<String, dynamic>.from(j) : const {}, plain: plain);
    } catch (_) {
      return (json: const {}, plain: utf8.decode(bytes, allowMalformed: true));
    }
  }

  static List<int>? _tryBase64(String s) {
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  static String _stripTags(String body) => body
      .replaceAll('<!--KG_TAG_RES_START-->', '')
      .replaceAll('<!--KG_TAG_RES_END-->', '')
      .trim();

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

  static String _md5(String s) => c.md5.convert(utf8.encode(s)).toString();

  /// mid = md5(随机 32 位十六进制串) 当成大整数写成的十进制串。
  static String _newMid() => BigInt.parse(_md5(_randomHex(32)), radix: 16).toString();

  static String _newDfid() {
    const pool = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return List.generate(24, (_) => pool[Random.secure().nextInt(pool.length)]).join();
  }

  static String _randomHex(int length) {
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[Random.secure().nextInt(16)]).join();
  }

  /// AES-128-CBC：key 和 iv 都从 md5(aesKey) 里切，前 16 位当 key、后 16 位当 iv。
  static String _aesEncrypt(String plain, String aesKey) {
    final h = _md5(aesKey);
    return base64.encode(_cbc(true, utf8.encode(plain), h.substring(0, 16), h.substring(16, 32)));
  }

  static String _aesDecryptBytes(List<int> bytes, String aesKey) {
    final h = _md5(aesKey);
    return utf8.decode(_cbc(false, bytes, h.substring(0, 16), h.substring(16, 32)),
        allowMalformed: true);
  }

  static Uint8List _cbc(bool encrypt, List<int> input, String key, String iv) {
    final cipher = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
      ..init(
        encrypt,
        pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>, Null>(
          pc.ParametersWithIV<pc.KeyParameter>(
              pc.KeyParameter(Uint8List.fromList(utf8.encode(key))),
              Uint8List.fromList(utf8.encode(iv))),
          null,
        ),
      );
    return cipher.process(Uint8List.fromList(input));
  }

  static String _rsaEncrypt(String plain) {
    final encryptor = pc.PKCS1Encoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pca.RSAPublicKey>(_publicKey()));
    return encryptor
        .process(Uint8List.fromList(utf8.encode(plain)))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static pca.RSAPublicKey _publicKey() {
    final der = base64.decode(_rsaKey);
    final outer = ASN1Parser(der).nextObject() as ASN1Sequence;
    final bitStr = outer.elements[1] as ASN1BitString;
    final inner = ASN1Parser(bitStr.contentBytes()).nextObject() as ASN1Sequence;
    return pca.RSAPublicKey(
      (inner.elements[0] as ASN1Integer).valueAsBigInteger,
      (inner.elements[1] as ASN1Integer).valueAsBigInteger,
    );
  }
}
