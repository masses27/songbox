import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';
import '../settings/app_settings.dart';
import '../util/json_body.dart';

/// QQ Music (tx) song search.
///
/// 这个模块的存在意义是「不装第三方音源也能换源」：搜索、取链、歌词全部端内直连，
/// 网易云撞墙的歌可以直接在 QQ 曲库里找同名版本。
class TxSearch {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    validateStatus: (s) => true,
    headers: const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      'Referer': 'https://y.qq.com/',
    },
  ));

  /// 同一个 CGI 在腾讯那边有镜像域名（本机实测两个都回同样的 JSON）。
  /// 她手机上撞过一次「HTTP 500 + 空响应」，而同一请求在本机四种 UA 全 200，
  /// 也就是这一条链路特有的问题：第一个不回话就换下一个，别把整条 QQ 换源一起判死。
  static const hosts = ['c.y.qq.com', 'c6.y.qq.com'];

  Future<SearchResult> search(String keyword, {int page = 1, int limit = 30}) async {
    Object? last;
    for (final host in hosts) {
      try {
        return await _searchOn(host, keyword, page: page, limit: limit);
      } catch (e) {
        last = e;
      }
    }
    throw Exception('腾讯搜索接口两个域名都没回话：${_bare(last)}');
  }

  /// `Exception` 拼进另一句 `Exception` 会把 `Exception: ` 一起带进去，屏幕上就成了
  /// 「都没回话：Exception: 腾讯搜索接口…」那种半通不通的话。
  static String _bare(Object? e) {
    final s = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 榜单号：27 新歌、4 流行指数、62 飙升、26 热歌。本机实测匿名各有 1~14 首没标付费的歌，
  /// 按免费数量从多到少排，通常第一个就够。
  static const _toplistIds = [27, 4, 62, 26];

  /// 从音乐榜单拿几首没标付费的歌，给「检测」和自检当对照曲用。
  ///
  /// 她手机上 `c.y.qq.com` 和 `c6.y.qq.com` 两个搜索域名同时回 HTTP 500，而取链用的
  /// `u.y.qq.com` 是通的——榜单就挂在同一个 `musicu.fcg` 上。搜索不回话不等于腾讯不回话，
  /// 这一行要量的是平台能不能出链，不是《晴天》这一首，所以拿榜单顶上。
  /// 全都标了付费时退回榜单前几首：至少能证明这条域名出得来数据，别把「没有免费歌」
  /// 报成「腾讯挂了」。
  static Future<List<Song>> toplistSongs({int count = 3}) async {
    final all = <Song>[];
    Object? last;
    for (final topid in _toplistIds) {
      try {
        all.addAll(await _toplist(topid));
      } catch (e) {
        last = e;
      }
      final free = all.where((s) => s.fee != 1);
      if (free.length >= count) break;
    }
    if (all.isEmpty) throw last ?? Exception('腾讯榜单没给歌');
    final ordered = Song.preferOriginal(all.where((s) => s.fee != 1));
    // 一首没标付费的都没有时退回整张榜单：这一支不是为了拿到免费歌，是为了证明
    // 这条域名出得来数据，所以照样先排原版。
    return (ordered.isEmpty ? Song.preferOriginal(all) : ordered).take(count).toList();
  }

  static Future<List<Song>> _toplist(int topid) async {
    final resp = await _dio.get('https://u.y.qq.com/cgi-bin/musicu.fcg', queryParameters: {
      'format': 'json',
      'data': jsonEncode({
        'comm': {'ct': 24, 'cv': 4747474, 'guid': AppSettings.instance.ensureTxGuid()},
        'req': {
          'module': 'musicToplist.ToplistInfoServer',
          'method': 'GetDetail',
          'param': {'offset': 0, 'num': 20, 'topid': topid},
        },
      }),
    });
    final raw = resp.data;
    if (raw is! String) throw Exception('腾讯榜单接口返回异常（HTTP ${resp.statusCode}）');
    final j = decodeBody(raw, status: resp.statusCode, label: '腾讯榜单接口');
    final data = (((j as Map?)?['req'] as Map?)?['data'] as Map?) ?? const {};
    final list = ((data['songInfoList'] as List?) ?? const [])
        .whereType<Map>()
        .map(parseToplistSong)
        .whereType<Song>()
        .toList();
    if (list.isEmpty) throw Exception('腾讯榜单 topid $topid 没给歌（HTTP ${resp.statusCode}）');
    return list;
  }

  /// 榜单条目的字段名和搜索接口不是一套：`mid`/`name`，付费标记写成 `pay_play`
  ///（搜索那边是 `payplay`）。字段认错就会把会员歌当成免费歌拿去试，白撞一次 104003。
  static Song? parseToplistSong(Map s) {
    final mid = '${s['mid'] ?? ''}';
    if (mid.isEmpty) return null;
    final album = (s['album'] as Map?) ?? const {};
    final albumMid = '${album['mid'] ?? ''}';
    return Song(
      songmid: mid,
      id: '${s['id'] ?? mid}',
      source: 'tx',
      name: '${s['name'] ?? ''}',
      singer: ((s['singer'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => '${e['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .join('、'),
      albumId: albumMid,
      albumName: '${album['name'] ?? ''}',
      pic: albumMid.isEmpty ? null : coverUrl(albumMid),
      interval: (s['interval'] as num?)?.toInt() ?? 0,
      fee: (s['pay'] as Map?)?['pay_play'] == 1 ? 1 : 0,
    );
  }

  Future<SearchResult> _searchOn(String host, String keyword, {int page = 1, int limit = 30}) async {
    final resp = await _dio.get('https://$host/soso/fcgi-bin/client_search_cp',
        queryParameters: {'format': 'json', 'p': page, 'n': limit, 'w': keyword});
    final raw = resp.data;
    if (raw is! String) throw Exception('腾讯搜索接口($host) 返回异常（HTTP ${resp.statusCode}）');
    final j = decodeBody(raw, status: resp.statusCode, label: '腾讯搜索接口($host)');
    final song = (j as Map?)?['data']?['song'];
    if (song is! Map) throw Exception('腾讯搜索接口($host) 返回异常（HTTP ${resp.statusCode}）');
    final list = ((song['list'] as List?) ?? const [])
        .whereType<Map>()
        .map(parseSong)
        .whereType<Song>()
        .toList();
    final total = (song['totalnum'] as num?)?.toInt() ?? list.length;
    return SearchResult(total, (total / limit).ceil().clamp(1, 9999), list);
  }

  static Song? parseSong(Map s) {
    final mid = '${s['songmid'] ?? ''}';
    if (mid.isEmpty) return null;
    final albumMid = '${s['albummid'] ?? ''}';
    return Song(
      songmid: mid,
      id: '${s['songid'] ?? mid}',
      source: 'tx',
      name: '${s['songname'] ?? ''}',
      singer: ((s['singer'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => '${e['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .join('、'),
      albumId: albumMid,
      albumName: '${s['albumname'] ?? ''}',
      pic: albumMid.isEmpty ? null : coverUrl(albumMid),
      interval: (s['interval'] as num?)?.toInt() ?? 0,
      // payplay=1 的歌匿名取链一定回 result:104003（实测），所以这一个数字就够用来
      // 筛换源候选，不必每首都发一次取链请求试。
      fee: (s['pay'] as Map?)?['payplay'] == 1 ? 1 : 0,
    );
  }

  /// 封面按 albummid 拼，300x300 是列表行够用的尺寸。
  static String coverUrl(String albumMid) =>
      'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg';
}
