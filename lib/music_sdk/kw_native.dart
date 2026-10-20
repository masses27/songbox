import 'dart:convert';

import 'package:dio/dio.dart';

/// Kuwo (kw) lyric straight from kuwo's public endpoint, so kw search results
/// and kw rankings get lyrics without a third-party lx-music source.
///
/// kw play URLs are NOT resolved here any more: antiserver only hands back a
/// ~11 second preview clip, which is worse than an honest failure.
class KwNative {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    responseType: ResponseType.plain,
    headers: {'User-Agent': 'Android-Kuwo/9.2.2.1'},
  ));

  /// LRC text for the given kuwo rid, or '' when unavailable.
  static Future<String> resolveLyric(String rid) async {
    try {
      final resp = await _dio.get<dynamic>(
        'https://www.kuwo.cn/openapi/v1/www/lyric/getlyric',
        queryParameters: {'musicId': rid, 'appui': 'ios1', 'https': '1'},
        options: Options(headers: {'User-Agent': 'Mozilla/5.0'}),
      );
      final body = resp.data;
      if (body is! String) return '';
      final j = jsonDecode(body);
      final list = (((j as Map?)?['data'] as Map?)?['lrclist']) as List?;
      if (list == null) return '';
      final sb = StringBuffer();
      for (final e in list) {
        if (e is! Map) continue;
        final text = e['lineLyric']?.toString() ?? '';
        final t = double.tryParse(e['time']?.toString() ?? '') ?? 0;
        final mm = (t / 60).floor();
        final ss = (t - mm * 60);
        sb.writeln('[${mm.toString().padLeft(2, '0')}:${ss.toStringAsFixed(2).padLeft(5, '0')}]$text');
      }
      return sb.toString();
    } catch (_) {
      return '';
    }
  }
}
