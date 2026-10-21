import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/song.dart';
import '../util/json_body.dart';

/// B 站（bl）：挡在会员墙后面的那条匿名整首路。
///
/// 本机 2026-10-20 实测：`search/type` 带一枚自己取的 `buvid3` 就能匿名搜，
/// `playurl?...&fnval=16` 回三条 dash 音轨，整首、匿名最高 192k，`…-30280.m4s`
/// 直接可播；同一轮里网易云和 QQ 的会员歌在所有公开取链接口上都只回空 url。
///
/// 所以这一层不是「又一个曲库」，而是放不出时的最后一档：换源只借它的音频，
/// 曲名、歌手、歌词、封面仍旧是原来那一首。
class BlSource {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36';

  /// 播放和下载这条音频都要带 `Referer`：本机六首实测有两首不带就 403，
  /// 而带上一律 206。just_audio 见到 headers 会走本机代理转发，行为不变。
  static const streamHeaders = {'User-Agent': _ua, 'Referer': 'https://www.bilibili.com/'};

  /// 这条地址要不要补上 B 站那对防盗链头——**只看地址，别看歌曲对象**。
  ///
  /// 换源拿回来的链接属于 B 站，可她队列里那一首仍然是网易云那首（`song.source`
  /// 还是 'wy'）。以前三处播放路径都按 `song.source == 'bl'` 决定，于是「会员墙后面
  /// 靠 B 站兜整首」这一整类歌——综艺现场、Live 版占大头——播的时候不带 Referer，
  /// 撞上那三成就只剩一句看不懂的 Source error。
  static Map<String, String>? headersFor(String url) => _cdn.hasMatch(url) ? streamHeaders : null;

  /// B 站的音轨域名有好几个镜像（`*.bilivideo.com`、`*.mcdn.bilivideo.cn`），
  /// 备用地址还挂在 `hdslb`/`bilibili.com` 上，按包含判比逐个列主机名稳。
  static final RegExp _cdn = RegExp(r'bilibili\.com|bilivideo|hdslb');

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    // 业务码在 body 里（-114 是没这条稿件、-404 是没权限），只看 HTTP 状态会错过它。
    validateStatus: (s) => true,
    headers: streamHeaders,
  ));

  /// 匿名搜索要一枚 `buvid3`：不带它 `search/type` 直接回 HTTP 412（实测），带上就正常出结果。
  /// 这枚号 `finger/spi` 随便问一次就给，跟账号无关，所以一次开屏拿一枚就够。
  static String? _buvid;

  /// 取号这一步也在并发路径上：整单体检时十几首同时搜 B 站，一人问一次会把
  /// `finger/spi` 打十几遍。共享同一次在途请求。
  static Future<String>? _fetching;

  static Future<String> _buvid3() async {
    final have = _buvid;
    if (have != null) return have;
    final running = _fetching;
    if (running != null) return running;
    late final Future<String> f;
    f = _askBuvid3().whenComplete(() {
      // 只撤自己这一次，别把失败后重新发起的那次也带走。
      if (identical(_fetching, f)) _fetching = null;
    });
    // 挂上必须在任何 await 之前：两首同时搜 B 站时，第二首要能看到这一趟在飞。
    return _fetching = f;
  }

  static Future<String> _askBuvid3() async {
    try {
      final resp = await _dio.get('https://api.bilibili.com/x/frontend/finger/spi');
      final data = resp.data;
      final j = data is String ? jsonDecode(data) : null;
      final b3 = '${((j as Map?)?['data'] as Map?)?['b_3'] ?? ''}';
      if (b3.isEmpty) throw Exception('没给 b_3');
      return _buvid = b3;
    } catch (e) {
      // 拿不到这枚号只是搜不了 B 站，别的源照旧，所以把话留在异常里、不缓存空值。
      throw Exception('B 站设备号没拿到（搜索会回 412）：$e');
    }
  }

  /// 问一次 B 站接口：`code != 0` 当场抛，抛出去的那句带着接口原话。
  static Future<Map<String, dynamic>> _api(String url, Map<String, dynamic> query, String label) async {
    final resp = await _dio.get(url,
        queryParameters: query, options: Options(headers: {'Cookie': 'buvid3=${await _buvid3()}'}));
    if (resp.statusCode == 412) {
      // 风控页是一段 HTML，走下面的「回的不是 JSON」只会让她看见一句天书。
      // 带着设备号还被拦，说明这枚号本身被记黑了：抱着它重试等于这一次开屏再也搜不了
      // B 站，扔掉，下次问一枚新的。
      _buvid = null;
      throw Exception('$label 把这次请求当成爬虫拦下了（HTTP 412），过一会儿再试');
    }
    final raw = resp.data;
    if (raw is! String) throw Exception('$label 返回异常（HTTP ${resp.statusCode}）');
    final j = decodeBody(raw, status: resp.statusCode, label: label);
    if (j is! Map) throw Exception('$label 返回异常（HTTP ${resp.statusCode}）');
    final code = (j['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw Exception('$label 回 code $code：${j['message'] ?? ''}');
    return Map<String, dynamic>.from(j);
  }

  /// 从 B 站找「就是这一首」的整首音频，最多 [max] 条，按靠得住的程度排。
  ///
  /// 标题是上传者自己写的，套不上曲库那套打分，所以这里自己把四道关：歌名和歌手都得
  /// 出现在标题里、时长对得上、明写了翻唱/伴奏/KTV 的直接不要、付费视频不要。
  /// 括号里那些【Hi-res】【4K60FPS】【杜比音效】是 B 站最常见的再封装标记，
  /// 不是分支版本——按通用换源那套「括号里不认识就否掉」会把最好的几条全删掉。
  static Future<List<Song>> findTwins(String name, String singer, {int? wantSec, int max = 2}) async {
    final bare = _bareName(name);
    if (bare.isEmpty) return const [];
    // 发出去的词只留曲名和第一个歌手：网易云把合唱写成「那英、华晨宇、艾薇 Ivy」，
    // 而现场版恰恰多半是合唱——整串丢给 B 站搜索基本搜不出东西。收紧的是关键词，
    // 判定照旧按全部歌手算（[pickVideos] 里命中一个就算数）。
    final firstSinger = singer.split(RegExp(r'[、&/／,，]')).first.trim();
    final body = await _api('https://api.bilibili.com/x/web-interface/search/type', {
      'search_type': 'video',
      'keyword': firstSinger.isEmpty ? bare : '$bare $firstSinger',
      'page': 1,
    }, 'B 站搜索');
    final results = ((body['data'] as Map?)?['result'] as List?) ?? const [];
    return pickVideos(results.whereType<Map>().toList(),
        wantName: name, wantSinger: singer, wantSec: wantSec, max: max);
  }

  /// 挑候选这一步单独拆出来，好把「标题怎么写才算同一首」钉进单测（这一层全靠它）。
  static List<Song> pickVideos(List<Map> videos,
      {required String wantName, required String wantSinger, int? wantSec, int max = 2}) {
    final name = _fold(wantName);
    final core = _fold(_bareName(wantName));
    // 合唱在曲库里写成「周杰伦、温岚」，B 站的标题常常只提其中一个，所以只要求对上一个。
    // 分隔符得先拆再折叠——折叠会把顿号一起抹掉，那时候再也分不出两个名字。
    final singers = wantSinger.split(RegExp(r'[、&/／,，]')).map(_fold).where((s) => s.length > 1).toList();
    final scored = <({Song song, double score})>[];
    for (final v in videos) {
      final raw = _cleanTitle('${v['title'] ?? ''}');
      final bvid = '${v['bvid'] ?? ''}'; // 列表里 `id`/`aid` 是数字 aid，取链要的是 bvid 那一串
      final folded = _fold(raw);
      if (bvid.isEmpty || !bvid.startsWith('BV') || folded.isEmpty) continue;
      // `is_pay` 在正常稿件上是 0，字段也可能整个不回；非 0 才是 B 站自己要付费的片子。
      final pay = v['is_pay'];
      if ((pay is num && pay != 0) || v['badgepay'] == true) continue;
      if (!folded.contains(name) && !folded.contains(core)) continue;
      if (singers.isNotEmpty && !singers.any(folded.contains)) continue;
      if (_branchVersion.hasMatch(raw)) continue;
      final sec = _durSec('${v['duration'] ?? ''}');
      double score = _fold(_inBrackets(raw)) == name ? 2.0 : 0.0; // 《晴天》这种把曲名写明的最可信
      if (wantSec != null && sec != null) {
        final d = (wantSec - sec).abs();
        if (d > 60) continue; // 四十三分钟的「单曲循环」合集不是这一首
        score += d <= 5 ? 2 : (d <= 20 ? 1.2 : 0);
        if (d > 20) score -= 2;
      }
      if (_liveVersion.hasMatch(raw)) score -= 1.5; // 现场版是另一个录音，能放但也得排在原版后面
      scored.add((song: _twin(bvid, raw, wantName, wantSinger, sec, v), score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(max).map((e) => e.song).toList();
  }

  /// 曲名、歌手仍旧用原来那一首的：换源只是借它的音频，列表上不该多出「【Hi-res】…」这种标题。
  static Song _twin(String bvid, String raw, String name, String singer, int? sec, Map v) {
    final pic = '${v['pic'] ?? ''}';
    return Song(
      songmid: bvid,
      source: 'bl',
      id: bvid,
      name: name,
      singer: singer,
      albumName: 'B 站',
      // 搜索给的是 `//i0.hdslb.com/…`，少了协议头 Image.network 直接报错。
      pic: pic.isEmpty ? null : (pic.startsWith('//') ? 'https:$pic' : pic),
      interval: sec,
    );
  }

  /// 一条 bvid → 能直接播的整首音频地址。两次请求：`pagelist` 拿 cid，`playurl` 拿音轨。
  static Future<String> resolveUrl(String bvid) async {
    final page = await _api('https://api.bilibili.com/x/player/pagelist', {'bvid': bvid}, 'B 站分 P 接口');
    final cid = (page['data'] as List?)?.whereType<Map>().firstOrNull?['cid'];
    if (cid == null) throw Exception('B 站这条视频没有第一 P（cid 为空）');
    final play = await _api('https://api.bilibili.com/x/player/playurl',
        {'bvid': bvid, 'cid': cid, 'fnval': 16, 'fourk': 1}, 'B 站取链接口');
    final dash = (play['data'] as Map?)?['dash'];
    final tracks = ((dash as Map?)?['audio'] as List?) ?? const [];
    // 匿名最多三条（64k/132k/192k），按带宽挑最高的那条。
    final best = tracks.whereType<Map>().toList()
      ..sort((a, b) => ((b['bandwidth'] as num?)?.toInt() ?? 0).compareTo((a['bandwidth'] as num?)?.toInt() ?? 0));
    final pick = best.firstOrNull;
    final url = pick == null ? '' : '${pick['baseUrl'] ?? (pick['backupUrl'] as List?)?.firstOrNull ?? ''}';
    if (url.isEmpty) {
      throw Exception(tracks.isEmpty ? 'B 站这条视频没给音轨（多半是会员专属稿）' : 'B 站给的音轨没带地址');
    }
    return url;
  }

  /// 直链尾巴上的 `…-30216.m4s` 就是档位号，检测那一行用它报实际拿到的音质。
  static String tierOfUrl(String url) {
    final m = RegExp(r'-(30\d{3})\.m4s').firstMatch(url);
    return switch (m?.group(1)) {
      '30216' => '64k',
      '30232' => '132k',
      '30280' => '192k',
      _ => '未知档位',
    };
  }

  /// 去掉搜索接口加的高亮标签（`<em class="keyword">晴天</em>`）。
  static String _cleanTitle(String s) => s.replaceAll(RegExp(r'</?em[^>]*>'), '');

  /// 曲名自己写在《》里；没写时整串标题当候选，靠上面的包含关去判。
  static String _inBrackets(String s) {
    final m = RegExp(r'《([^》]{1,40})》').firstMatch(s);
    return m?.group(1) ?? '';
  }

  /// 网易云那边有些歌写成「晴天 (Live)」「修炼爱情（现场版）」，B 站的标题不会有这段，
  /// 所以拿来比对时先把括号尾巴摘掉。
  static String _bareName(String s) =>
      s.replaceAll(RegExp(r'[（(【\[].*?[）)】\]]'), '').replaceAll(RegExp(r'\s+(版|live)$', caseSensitive: false), '').trim();

  static int? _durSec(String s) {
    final parts = s.split(':').map((e) => int.tryParse(e.trim()) ?? -1).toList();
    if (parts.any((p) => p < 0)) return null;
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    return null;
  }

  static final RegExp _foldNoise = RegExp(r"[\s\-－_·．.,，、()（）\[\]【】/｜'’《》:：]");

  static String _fold(String s) => s.toLowerCase().replaceAll(_foldNoise, '');

  /// B 站上传者的花活比曲库多：除了伴奏、翻唱，还有 KTV 字幕版和「纯享」。
  static final RegExp _branchVersion = RegExp(
      r'翻唱|cover|伴奏|伴唱|纯音乐|无人声|ktv|karaoke|降调|升调|变调|加速|慢速|dj|remix|混音|'
      r'钢琴|古筝|二胡|大提琴|萨克斯|音乐盒|八音盒|清唱|片段|试听|预听',
      caseSensitive: false);

  static final RegExp _liveVersion = RegExp(r'live|现场|演唱会|concert|mv|饭拍|直拍', caseSensitive: false);
}
