/// 网易云封面地址的统一改写。
///
/// 接口给的是 `http://p1.music.126.net/xxx.jpg?imageView=1&thumbnail=800y800…`
/// 这一长串它自家的缩放/水印指令（多条用 `%7C` 拼起来）。手机上这一串经常整条
/// 取不到图——列表里就只剩占位渐变；偶尔取到了也是 600KB～1MB 的原图。
/// 换成 `https://` + `?param=NNNyNNN` 是同一张图，实测 300 方的约 130KB。
///
/// 尺寸只落到几档固定值：同一屏的请求命中同一份缓存，翻页面时不用再下一遍。
library;

const _steps = [120, 200, 300, 400, 600];

/// 图片请求要带的头。
///
/// 网易云的封面 CDN 认 UA：dart:io 的默认值（`Dart/3.x (dart:io)`）一律 403，
/// 换成浏览器 UA 就是 200 —— 而 `HttpClient.defaultUserAgent` 没有 setter，
/// 只能每个请求自己带。Referer 反而不是必须的（不带也 200），留着当保险。
const artHeaders = {
  'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Referer': 'https://music.163.com/',
};

/// [px] 是这块位置大概需要多少物理像素（逻辑边长 × devicePixelRatio）。
String? artUrl(String? raw, {int px = 300}) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s);
  final host = uri?.host ?? '';
  if (uri == null || uri.path.isEmpty) return s;
  if (uri.scheme != 'http' && uri.scheme != 'https') return s;
  if (!host.endsWith('music.126.net') && !host.endsWith('music.163.com')) return s;
  final size = _steps.firstWhere((e) => e >= px, orElse: () => _steps.last);
  // 路径里带 == 和 +，是签名的一部分，只能按原样截断，不能过一遍 Uri.path 的解码。
  final cut = s.indexOf('?');
  final clean = (cut < 0 ? s : s.substring(0, cut)).replaceFirst('http://', 'https://');
  return '$clean?param=${size}y$size';
}
