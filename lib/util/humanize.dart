/// 是不是「连不上」这一类失败（而不是这首歌本身放不出）。
///
/// 决定点是接下来等一等重试同一首、还是跳下一首：断网时整条取链子都会报连不上，
/// 往下跳只是把剩下的歌一路标成放不出。超时也算进来——音源脚本卡死多半就是网络。
bool looksLikeNetworkFailure(Object e) {
  final s = '$e';
  return _networkMarks.any(s.contains);
}

const _networkMarks = [
  'SocketException',
  'Failed host lookup',
  'Network is unreachable',
  'ENETUNREACH',
  'ECONNRESET',
  'Connection refused',
  'ECONNREFUSED',
  'Connection closed',
  'Connection timed out',
  'TimeoutException',
  'network error',
];

/// 是不是「这次问得不凑巧」这一类失败：平台把出口 IP 当成爬虫（B 站回 HTTP 412、
/// 腾讯回 104009 invalidq），或者答得太快太慢。
///
/// 换源那条链子会把「确实没有免费版」的判定落盘一周，而这类失败跟这首歌一点关系都没有：
/// 整单体检几十首连着发出去，撞上一次的就不该把那一串歌全判死。
/// 判据刻意写窄，宁可漏判也不能把「这首真的没有」误判成限流。
bool looksLikeThrottle(Object e) {
  final s = '$e';
  return _throttleMarks.any((m) => s.contains(m));
}

/// 「返回异常」= 接口答的不是 JSON。各家接口正常时一定有 `code`，回一段 HTML
/// 风控页或空 body 只有拦截和故障两种解释，跟这首歌有没有版权无关，所以算这一类。
/// `code -352` 是 B 站取音频时的风控码，和 412 同一回事。
const _throttleMarks = [
  'HTTP 412',
  'code -412',
  'code -352',
  '爬虫',
  '104009',
  '判成无效',
  '被限流',
  '返回异常',
];

/// 是不是「挡在会员墙后面」这一类失败。
///
/// 这类错重试没有意义，界面上要立刻给「换版本」，播放器也不再把它算成网络故障。
/// 判据写得宽一点：各源的话术不统一（网易云「会员专享 / VIP 专属」、腾讯「也要会员」、
/// 音源脚本回原文），漏掉一种就少给一次换版本的机会。
bool looksLikeVipWall(Object? e) {
  final s = '$e';
  return _vipMarks.any((m) => s.contains(m));
}

const _vipMarks = ['会员专享', 'VIP 专属', '要会员'];

/// Turns plugin/transport exceptions into something a user can act on.
String humanizeError(Object e) {
  final s = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '$e';
  if (looksLikeNetworkFailure(e) || s.contains('ClientException')) {
    return '网络连接不通，确认手机能上网后重试';
  }
  return s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

/// 播放量这类大数字：7 位数以上写「万」「亿」，跟网易云一样，
/// 否则卡片上会出现 12345678 这种没法一眼读的长度。
String fmtCount(int n) {
  if (n < 10000) return '$n';
  if (n < 100000000) return _trim(n / 10000, '万');
  return _trim(n / 100000000, '亿');
}

String _trim(double v, String unit) {
  final one = (v * 10).round() / 10;
  return one == one.round() ? '${one.round()}$unit' : '${one.toStringAsFixed(1)}$unit';
}
