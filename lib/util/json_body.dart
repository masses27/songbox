import 'dart:convert';

/// 把接口回的那段文本解成 JSON，失败时说的是能拿去定位的话。
///
/// 这些 `fcg` / `weapi` 端点全挂了 `validateStatus: (code) => true`（要读业务错误码，
/// 不能只看 HTTP 状态），代价是 400/403 那种空 body 会一路走到 `jsonDecode('')`，
/// 冒出来的是 `FormatException: Unexpected end of input (at character 1)`——
/// 她看见的是一句天书，我们连是哪个接口、服务器答了什么都没留下。
Object? decodeBody(String raw, {required int? status, required String label}) {
  if (raw.trim().isEmpty) throw Exception('$label 没回话（HTTP $status）');
  try {
    return jsonDecode(raw);
  } on FormatException {
    final head = raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
    throw Exception('$label 回的不是 JSON（HTTP $status）：$head');
  }
}
