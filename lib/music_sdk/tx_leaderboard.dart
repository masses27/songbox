import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/results.dart';
import '../models/song.dart';
import '../settings/app_settings.dart';
import '../util/json_body.dart';
import 'tx_search.dart';

/// QQ 音乐（tx）榜单：总表 + 单榜曲目，全部匿名，走取链那条 `u.y.qq.com`。
///
/// 接这一家不是为了多几个榜名 —— 发现页原来只有网易云和酷我两张表，同一首歌在
/// QQ 曲库里的版本本来就另一套；而且榜单和取链同域名，她手机上那两个搜索域名
/// 同时回 HTTP 500 的那段日子，这一条还是通的（见 [TxSearch.toplistSongs]）。
class TxLeaderboard {
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

  /// 一屏 30 首：接口 `num` 给到 60 也收（实测回满 60 条），但翻页粒度按 30 更稳，
  /// 和网易云那张表的分页手感一致。
  static const pageLimit = 30;

  /// 不放视频的这个 App 里点开只会是一场空等，所以从表里剔掉。
  static const _noAudioTopIds = {201};

  /// 四组三十来张榜，组名（巅峰榜/地区榜/特色榜/全球榜）直接带给发现页分组用。
  Future<List<RankInfo>> get list async {
    final out = parseBoards(await _call('GetAll', const {}));
    if (out.isEmpty) throw Exception('QQ 榜单总表没给榜');
    return out;
  }

  /// 总表那张 JSON 切成榜单卡片。单独抽出来是为了能钉进单测：分组名、`topId`/`title`
  /// 这些字段名、以及「MV榜要剔掉」这一条，全是看一眼看不出错的地方。
  static List<RankInfo> parseBoards(Map? data) {
    final out = <RankInfo>[];
    for (final g in (data?['group'] as List? ?? const []).whereType<Map>()) {
      final groupName = '${g['groupName'] ?? ''}'.trim();
      for (final t in (g['toplist'] as List? ?? const []).whereType<Map>()) {
        final id = (t['topId'] as num?)?.toInt() ?? 0;
        final name = '${t['title'] ?? ''}'.trim();
        if (id == 0 || name.isEmpty || _noAudioTopIds.contains(id)) continue;
        final total = (t['totalNum'] as num?)?.toInt() ?? 0;
        out.add(RankInfo(
          'tx',
          '$id',
          name,
          img: httpsCover(t['frontPicUrl']?.toString()),
          desc: total > 0 ? '$total 首' : null,
          group: groupName.isEmpty ? null : groupName,
        ));
      }
    }
    return out;
  }

  /// 一张榜的一页。`offset` 真的在翻页（实测 0/30 两批不重样），所以这里能上滑到底。
  Future<SearchResult> getList(String topId, {int page = 1, int limit = pageLimit}) async {
    final id = int.tryParse(topId);
    if (id == null) throw Exception('QQ 榜单号看不懂：$topId');
    final data = await _call('GetDetail', {'offset': (page - 1) * limit, 'num': limit, 'topid': id});
    final list = ((data?['songInfoList'] as List?) ?? const [])
        .whereType<Map>()
        .map(TxSearch.parseToplistSong)
        .whereType<Song>()
        .toList();
    // 总曲数在 data 里那一层（飙升榜 100、热歌榜 300）：拿它算页数，界面才知道
    // 什么时候才是真翻到头了。
    final total = ((data?['data'] as Map?)?['totalNum'] as num?)?.toInt() ?? 0;
    final all = total > 0 ? total : list.length;
    return SearchResult(all, (all / limit).ceil().clamp(1, 999), list);
  }

  Future<Map?> _call(String method, Map param) async {
    final resp = await _dio.get('https://u.y.qq.com/cgi-bin/musicu.fcg', queryParameters: {
      'format': 'json',
      'data': jsonEncode({
        'comm': {'ct': 24, 'cv': 4747474, 'guid': AppSettings.instance.ensureTxGuid()},
        'req': {'module': 'musicToplist.ToplistInfoServer', 'method': method, 'param': param},
      }),
    });
    final raw = resp.data;
    if (raw is! String) throw Exception('QQ 榜单接口($method) 返回异常（HTTP ${resp.statusCode}）');
    final j = decodeBody(raw, status: resp.statusCode, label: 'QQ 榜单接口($method)');
    final req = (j as Map?)?['req'];
    return (req is Map ? req['data'] : null) as Map?;
  }

  /// 接口给的封面是 `http://`。安卓那边虽然开了 cleartext，桌面版和没开的应用可不认，
  /// 同一张图换成 https 实测一模一样，没有留的理由。
  static String? httpsCover(String? url) {
    final s = url?.trim() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http://') ? 'https://${s.substring(7)}' : s;
  }
}
