import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';

import 'native_funcs.dart';

class LxSourceSupport {
  final List<String> sources;
  final Map<String, List<String>> qualitys;
  final Map<String, List<String>> actions;
  LxSourceSupport(this.sources, this.qualitys, this.actions);
}

/// Runs one lx-protocol (v2.0.0) source script inside QuickJS,
/// bridging network/timer/crypto through a synchronous channel + Dart callbacks.
class LxEngine {
  JavascriptRuntime? _rt;
  final _random = Random();
  final Map<String, Completer<Map<String, dynamic>>> _waitingForScriptResponse = {};
  final Map<String, CancelToken> _httpCancelTokens = {};
  final Dio _dio = Dio(BaseOptions(receiveDataWhenStatusError: true, validateStatus: (status) => true));
  final List<Timer> _timers = [];
  LxSourceSupport? support;
  bool inited = false;
  String? initError;
  final String _key;
  final Completer<void> _initSignal = Completer<void>();

  LxEngine() : _key = 'k${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(99999)}';

  static LxEngine? active;

  Future<void> loadScript(
    String scriptText, {
    required String name,
    required String description,
    required String version,
    required String author,
    required String homepage,
  }) async {
    dispose();
    final rt = getJavascriptRuntime();
    rt.initChannelFunctions();
    rt.onMessage('n', _onNativeCall);
    _rt = rt;
    final bootstrap = await rootBundle.loadString('assets/js/lx_bootstrap.js');
    _eval(bootstrap);
    _eval(
      'lx_setup(${jsStr(_key)}, ${jsStr(name)}, ${jsStr(description)}, ${jsStr(version)}, ${jsStr(author)}, ${jsStr(homepage)}, ${jsStr(scriptText.length > 2000000 ? scriptText.substring(0, 2000000) : scriptText)});',
    );
    _eval(scriptText);
    _drain();
    // Some scripts (sixyin/lx etc.) fire an HTTP request during init and only
    // call lx.send('inited', ...) once it returns, so we must wait for the
    // init callback instead of trusting the synchronous flag alone.
    try {
      await _initSignal.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      initError ??= '初始化超时：脚本 20 秒内没有就绪，多半是它依赖的接口已经失效';
    }
  }

  dynamic _onNativeCall(dynamic msg) {
    final action = msg?['action'] as String?;
    final data = msg?['data'];
    switch (action) {
      case 'md5':
        return NativeFuncs.md5(data as String);
      case 'sha1':
        return NativeFuncs.sha1(data as String);
      case 'str2b64':
        return NativeFuncs.str2b64(data as String);
      case 'b642buf':
        return NativeFuncs.b642buf(data as String);
      case 'aes':
        return NativeFuncs.aes(Map<String, dynamic>.from(data as Map));
      case 'rsa':
        return NativeFuncs.rsa(Map<String, dynamic>.from(data as Map));
      case 'inflate':
        return NativeFuncs.inflate(Map<String, dynamic>.from(data as Map));
      case 'deflate':
        return NativeFuncs.deflate(Map<String, dynamic>.from(data as Map));
      case 'gbk':
        return NativeFuncs.b642str((data as Map)['data'] as String);
      case 'timer':
        final id = data['id'];
        final ms = (data['ms'] as num?)?.toInt() ?? 0;
        // 触发后必须把自己从 _timers 里摘掉：脚本每首歌都会排一批定时器，
        // 只在 dispose 时清空的话，长跑的引擎会攒下上万个已完成的 Timer。
        late final Timer t;
        t = Timer(Duration(milliseconds: ms), () {
          _timers.remove(t);
          _callJsRaw('__lx_timer_fire__($id)');
        });
        _timers.add(t);
        return null;
      case 'http':
        _doHttp(data as Map);
        return null;
      case 'request':
        _doScriptRequest(data as Map);
        return null;
      case 'cancelRequest':
        _httpCancelTokens.remove(data as String)?.cancel();
        return null;
      case 'response':
        final d = data as Map;
        final key = d['requestKey'] as String;
        final completer = _waitingForScriptResponse.remove(key);
        if (completer != null) {
          if (d['status'] == true) {
            completer.complete(Map<String, dynamic>.from(d['result'] as Map));
          } else {
            completer.completeError(Exception(d['errorMessage'] ?? 'request failed'));
          }
        }
        return null;
      case 'init':
        final d = data as Map;
        if (d['status'] == true) {
          final info = Map<String, dynamic>.from(d['info'] as Map);
          final sourcesMap = Map<String, dynamic>.from(info['sources'] as Map);
          support = LxSourceSupport(
            sourcesMap.keys.toList(),
            sourcesMap.map((k, v) => MapEntry(k, List<String>.from((v as Map)['qualitys'] as List))),
            sourcesMap.map((k, v) => MapEntry(k, List<String>.from((v as Map)['actions'] as List))),
          );
          inited = true;
        } else {
          initError = d['errorMessage']?.toString();
        }
        if (!_initSignal.isCompleted) _initSignal.complete();
        return null;
      case 'showUpdateAlert':
        return null;
    }
    return null;
  }

  /// Send a request INTO the user script (musicUrl / lyric / pic actions).
  Future<Map<String, dynamic>> sendRequest(
    String source,
    String action,
    Map<String, dynamic> info, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!inited) throw Exception('source not inited');
    final requestKey = 'r${_random.nextInt(0x7fffffff)}';
    final completer = Completer<Map<String, dynamic>>();
    _waitingForScriptResponse[requestKey] = completer;
    _callJs('__lx_js_call__', ['request', jsonEncode({'requestKey': requestKey, 'source': source, 'action': action, 'info': info})]);
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _waitingForScriptResponse.remove(requestKey);
    }
  }

  void _doScriptRequest(Map data) {
    final url = data['url'] as String;
    final options = Map<String, dynamic>.from(data['options'] as Map? ?? {});
    final requestKey = data['requestKey'] as String;
    final cancelToken = CancelToken();
    _httpCancelTokens[requestKey] = cancelToken;
    _rawRequest(url, options, cancelToken).then((resp) {
      _httpCancelTokens.remove(requestKey);
      _callJs('__lx_js_call__', ['response', jsonEncode({'requestKey': requestKey, 'error': null, 'response': resp})]);
    }).catchError((e) {
      _httpCancelTokens.remove(requestKey);
      _callJs('__lx_js_call__', ['response', jsonEncode({'requestKey': requestKey, 'error': '$e', 'response': null})]);
    });
  }

  Future<Map<String, dynamic>> _rawRequest(String url, Map<String, dynamic> options, CancelToken cancelToken) async {
    final method = (options['method'] ?? 'get').toString().toUpperCase();
    final headers = <String, dynamic>{};
    (options['headers'] as Map?)?.forEach((k, v) => headers['$k'] = '$v');
    final timeoutMs = (options['timeout'] as num?)?.toInt() ?? 15000;
    Object? body;
    if (options['form'] != null) {
      final form = options['form'] as Map;
      body = form.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      headers['content-type'] ??= 'application/x-www-form-urlencoded';
    } else if (options['formData'] != null) {
      final fd = options['formData'] as Map;
      body = FormData.fromMap(fd.map((k, v) => MapEntry(k.toString(), v)));
    } else if (options['body'] != null) {
      body = options['body'];
      if (body is Map || body is List) {
        body = jsonEncode(body);
        headers['content-type'] ??= 'application/json';
      }
    }
    final opt = Options(
      method: method,
      headers: headers,
      responseType: options['binary'] == true ? ResponseType.bytes : ResponseType.plain,
      sendTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
    );
    final resp = await _dio.request(url, data: body, options: opt, cancelToken: cancelToken);
    final respHeaders = <String, String>{};
    resp.headers.forEach((k, v) => respHeaders[k] = v.join(', '));
    dynamic responseBody = resp.data;
    if (responseBody is List<int>) {
      responseBody = String.fromCharCodes(responseBody);
    }
    return {
      'statusCode': resp.statusCode ?? 0,
      'statusMessage': resp.statusMessage ?? '',
      'headers': respHeaders,
      'body': responseBody,
    };
  }

  void _doHttp(Map data) {
    final id = data['id'].toString();
    final url = data['url'] as String;
    final options = Map<String, dynamic>.from(data['options'] as Map? ?? {});
    final cancelToken = CancelToken();
    _rawRequest(url, options, cancelToken).then((resp) {
      _callJsRaw(
        '__lx_http_done__($id, null, ${resp['statusCode']}, '
        '${jsonEncode(jsonEncode(resp['headers']))}, ${jsonEncode(resp['body'])}, null)',
      );
    }).catchError((e) {
      _callJsRaw('__lx_http_done__($id, ${jsonEncode('$e')}, 0, null, null, null)');
    });
  }

  void _callJs(String fn, List<String> args) {
    _eval('try { $fn(${args.map(jsonEncode).join(',')}); } catch (e) {}');
    _drain();
  }

  void _callJsRaw(String jsExpr) {
    _eval('try { $jsExpr; } catch (e) {}');
    _drain();
  }

  void _drain() {
    _rt?.executePendingJob();
  }

  void _eval(String code) {
    _rt?.evaluate(code);
    _rt?.executePendingJob();
  }

  static String jsStr(String s) => jsonEncode(s);

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final c in _httpCancelTokens.values) {
      c.cancel();
    }
    _httpCancelTokens.clear();
    inited = false;
    support = null;
    try {
      _rt?.dispose();
    } catch (_) {}
    _rt = null;
  }
}
