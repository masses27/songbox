import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart' show Color;

/// 播放页跟着歌变色用的封面主色。
///
/// 图先按 32×32 解码，再只让有彩色的像素按饱和度投票——纯黑边、白底和过曝高光
/// 都拉不出这首歌的调性，参与进来只会得到一个发灰的颜色。结果按 URL 缓存，
/// 同一首重播不再重复下载。
class CoverTint {
  CoverTint._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'},
  ));

  static final Map<String, Color> _cache = {};
  static const int _maxCache = 40;

  /// 已经算过的颜色，同步返回，用来避免每次 rebuild 都重新取一次。
  static Color? peek(String url) => _cache[url];

  static Future<Color?> get(String url) async {
    final hit = _cache[url];
    if (hit != null) return hit;
    try {
      final resp = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      final raw = resp.data;
      if (raw == null) return null;
      final color = await _dominant(Uint8List.fromList(raw));
      if (color == null) return null;
      if (_cache.length >= _maxCache) _cache.clear();
      _cache[url] = color;
      return color;
    } catch (_) {
      return null;
    }
  }

  static Future<Color?> _dominant(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 32, targetHeight: 32);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final px = data.buffer.asUint8List();
      double r = 0, g = 0, b = 0, w = 0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        if (px[i + 3] < 128) continue;
        final max = math.max(px[i], math.max(px[i + 1], px[i + 2]));
        final min = math.min(px[i], math.min(px[i + 1], px[i + 2]));
        final sat = max == 0 ? 0.0 : (max - min) / max;
        final val = max / 255;
        if (sat < .18 || val < .15 || val > .95) continue;
        r += px[i] * sat;
        g += px[i + 1] * sat;
        b += px[i + 2] * sat;
        w += sat;
      }
      if (w <= 0) return null;
      r /= w;
      g /= w;
      b /= w;
      // 归一到满色再压暗，不然取到的是被大面积留白稀释过的淡色。
      final k = 200 / math.max(r, math.max(g, b));
      return Color.fromARGB(
        255,
        (r * k).clamp(0, 255).round(),
        (g * k).clamp(0, 255).round(),
        (b * k).clamp(0, 255).round(),
      );
    } finally {
      image.dispose();
    }
  }
}
