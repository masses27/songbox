import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';
import 'wy_native.dart';

/// NetEase (wy) song search via the official web search API (no auth needed).
class WySearch {
  /// 主路：网页版搜索框自己在用的那个，匿名、不限关键词。
  static const _cloud = 'https://music.163.com/api/cloudsearch/pc';

  /// 兜底：原来一直在用的老接口，被按 IP 风控（见 [_search]）。
  static const _legacy = 'https://music.163.com/api/search/get/web?csrf_token=';

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    headers: const {
      'User-Agent': 'Mozilla/5.0',
      'Referer': 'https://music.163.com/',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
  ));

  /// 网易云自己的两个搜索接口：主路是网页版搜索框在用的 cloudsearch，
  /// 老的那个（`/api/search/get/web`）只在主路没答话时兜一次底。
  ///
  /// 换掉是有实测原因的：老接口按出口 IP 风控，从同一个地址连打十几个词之后
  /// 对**所有**关键词一律回 `code:405` 且不带 result —— 「晴天」「周杰伦」也一样。
  /// 以前这被读成「搜到了 0 条」，界面上就成了「没这个歌手」，换源那条链子还会顺手
  /// 把这首歌打上「确认没有免费版」的标记，一判就是一周。
  /// cloudsearch 匿名连打几十次全部 200，同一批词的结果数跟老接口一模一样。
  Future<Map?> _search(String keyword, int type, int page, int limit) async {
    final offset = (page - 1) * limit;
    final form = 's=${Uri.encodeQueryComponent(keyword)}&type=$type&offset=$offset&limit=$limit';
    Object? cloudError;
    try {
      return await _post(_cloud, '$form&total=true');
    } catch (e) {
      cloudError = e;
    }
    // 兜底那条就是原来的老接口：主路被掐时它大概率也一起被掐，但两条都问一遍才敢说
    // 「这次搜不到」。两句都要留下，但各自截短——整条消息要在界面上一行放得下。
    try {
      return await _post(_legacy, form);
    } catch (e) {
      throw Exception('${_brief(cloudError)}；备用接口也没答话（${_brief(e)}）');
    }
  }

  /// 一句错误压成界面放得下的一小段。
  ///
  /// DioException 的整串开头是固定的包装话术（`DioException [connection error]: The
  /// connection errored: …`），「Failed host lookup」「SocketException」这些字样要到
  /// 第 57 个字符往后才出现 —— 而 `looksLikeNetworkFailure` 正是靠它们把这次失败算成
  /// 「问得不凑巧」。截断要是把它们切掉，断网搜不到就会被当成「这首歌真没有免费版」，
  /// 一判就是一周。所以先取内层那条原始错误（它本身就是最短最准的一句），再截。
  static String _brief(Object e) {
    final inner = e is DioException ? '${e.error ?? e.message}' : '$e';
    final s = inner.replaceAll(RegExp(r'\s+'), ' ').replaceFirst('Exception: ', '').trim();
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  /// 一次搜索请求：把「接口答了但没给结果」和「确实没有这首歌」分开。
  ///
  /// 网易云限流时回的是 HTTP 200 + `code:405/406` + 没有 result，光看 HTTP 状态码
  /// 看不出来；风控页那种连 JSON 都不是的回法也算进来。报出去的那句一定带「被限流」，
  /// `looksLikeThrottle` 认这个标记 —— 换源那条链子据此决定要不要把歌打上死标。
  static Future<Map?> _post(String url, String body) async {
    Response resp;
    try {
      resp = await _dio.post(url, data: body);
    } on DioException catch (e) {
      // 带回执的 HTTP 错误（风控页、429）也算「接口没答话」；连不上和超时留给
      // looksLikeNetworkFailure 认，两条路都不该把这首歌判成放不出。
      final status = e.response?.statusCode;
      if (status != null) throw Exception('网易云搜索被限流：HTTP $status');
      rethrow;
    }
    final raw = resp.data;
    if (raw is! String) throw Exception('网易云搜索被限流：回的不是文本（HTTP ${resp.statusCode}）');
    Map? j;
    try {
      j = jsonDecode(raw) as Map?;
    } catch (_) {
      throw Exception('网易云搜索被限流：回的不是 JSON（HTTP ${resp.statusCode}）');
    }
    final result = j?['result'];
    if (result is! Map) {
      throw Exception('网易云搜索被限流：code=${j?['code']} 且没带结果，过一会儿再试');
    }
    return result;
  }

  Future<SearchResult> search(String keyword, {int page = 1, int limit = 30}) async {
    final result = await _search(keyword, 1, page, limit);
    final songs = (result?['songs'] as List?) ?? const [];
    final list = songs.map(parseSong).whereType<Song>().toList();
    final total = (result?['songCount'] as num?)?.toInt() ?? list.length;
    return SearchResult(total, (total / limit).ceil().clamp(1, 9999), list);
  }

  /// 歌手 tab.
  Future<({int total, List<ArtistInfo> list})> searchArtists(String keyword,
      {int page = 1, int limit = 30}) async {
    final result = await _search(keyword, 100, page, limit);
    final arr = (result?['artists'] as List?) ?? const [];
    final list = arr.map((e) => ArtistInfo.fromNetEase(e as Map)).whereType<ArtistInfo>().toList();
    return (
      total: (result?['artistCount'] as num?)?.toInt() ?? list.length,
      list: list
    );
  }

  /// 专辑 tab.
  Future<({int total, List<AlbumInfo> list})> searchAlbums(String keyword,
      {int page = 1, int limit = 30}) async {
    final result = await _search(keyword, 10, page, limit);
    final arr = (result?['albums'] as List?) ?? const [];
    final list = arr.map((e) => AlbumInfo.fromNetEase(e as Map)).whereType<AlbumInfo>().toList();
    return (total: (result?['albumCount'] as num?)?.toInt() ?? list.length, list: list);
  }

  /// 歌单 tab.
  Future<({int total, List<SheetInfo> list})> searchSheets(String keyword,
      {int page = 1, int limit = 30}) async {
    final result = await _search(keyword, 1000, page, limit);
    final arr = (result?['playlists'] as List?) ?? const [];
    final list = arr.whereType<Map>().map((e) {
      final img = e['coverImgUrl']?.toString();
      return SheetInfo('wy', '${e['id']}', '${e['name'] ?? ''}',
          (img == null || img.isEmpty) ? null : img, '${e['description'] ?? ''}'.trim(),
          playCount: num.tryParse('${e['playCount'] ?? 0}')?.toInt() ?? 0);
    }).where((s) => s.id.isNotEmpty && s.name.isNotEmpty).toList();
    return (
      total: (result?['playlistCount'] as num?)?.toInt() ?? list.length,
      list: list
    );
  }

  /// 搜索联想 — 网页版搜索框下拉用的同一个接口，端内 weapi 签名就够，不用登录。
  Future<List<SuggestItem>> suggest(String keyword) async {
    final body = await WyNative.weapi({'frag': '0', 's': keyword}, '/weapi/search/suggest/web');
    final res = body['result'];
    if (res is! Map) return const [];
    final out = <SuggestItem>[];
    for (final s in (res['songs'] as List? ?? const []).whereType<Map>()) {
      final name = s['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final by = ((s['artists'] as List? ?? const []).whereType<Map>())
          .map((a) => a['name']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .join(' / ');
      out.add(SuggestItem(name, by.isEmpty ? '单曲' : by));
      if (out.length == 6) break;
    }
    for (final a in (res['artists'] as List? ?? const []).whereType<Map>()) {
      final name = a['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      out.add(SuggestItem(name, '歌手 · ${(a['musicSize'] as num?)?.toInt() ?? 0} 首'));
      if (out.length == 8) break;
    }
    return out;
  }

  /// 热搜词 — 搜索页空态用，接口一次给十条。
  static Future<List<String>> hotWords({int limit = 10}) async {
    final body = await WyNative.weapi({'type': 1, 'apply': 0, 'time': '0'}, '/weapi/search/hot');
    final hots = ((body['result'] as Map?)?['hots'] as List?) ?? const [];
    return hots
        .whereType<Map>()
        .map((e) => e['first']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .take(limit)
        .toList();
  }

  /// Parses a NetEase song object in either the legacy shape (`artists` /
  /// `album` / `duration`) or the v3 shape (`ar` / `al` / `dt`), both of which
  /// show up across the search, rank and playlist endpoints.
  static Song? parseSong(dynamic s) {
    if (s is! Map) return null;
    final id = '${s['id']}';
    final artists = (s['artists'] ?? s['ar']) as List?;
    final album = (s['album'] ?? s['al']) as Map?;
    final duration = s['duration'] ?? s['dt'];
    return Song(
      songmid: id,
      id: id,
      source: 'wy',
      name: '${s['name'] ?? ''}',
      singer: artists?.map((a) => '${(a as Map?)?['name'] ?? ''}').where((n) => n.isNotEmpty).join('、') ?? '',
      albumId: '${album?['id'] ?? ''}',
      albumName: '${album?['name'] ?? ''}',
      pic: album?['picUrl']?.toString(),
      interval: ((duration as num?)?.toInt() ?? 0) ~/ 1000,
      fee: (s['fee'] as num?)?.toInt() ?? 0,
    );
  }
}
