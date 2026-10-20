'use strict';
// LX music source protocol (v2.0.0) runtime shim for QuickJS/flutter_js.
// Mirrors lx-music-mobile's android user-api-preload.js, but the native
// transport is: JS -> Dart synchronous calls via `sendMessage('n', ...)`
// and Dart -> JS callbacks via `globalThis.__lx_js_call__(action, data)`.

(function () {
  const pendingTimers = {};
  const pendingRequests = {};
  const httpPendings = {};
  let timerSeq = 0;
  let reqSeq = 0;

  const nativeSync = (action, data) => {
    const raw = sendMessage('n', JSON.stringify({ action: action, data: data }));
    if (raw == null) return null;
    try { return typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { return raw; }
  };

  // ---- Dart -> JS entry points -------------------------------------------
  globalThis.__lx_timer_fire__ = function (id) {
    const cb = pendingTimers[id];
    if (!cb) return;
    delete pendingTimers[id];
    cb();
  };

  globalThis.__lx_http_done__ = function (id, errStr, statusCode, headersJson, bodyStr, rawB64) {
    const p = httpPendings[id];
    if (!p) return;
    delete httpPendings[id];
    if (errStr) return p.reject(new Error(errStr));
    p.resolve({
      statusCode: statusCode,
      headers: headersJson ? JSON.parse(headersJson) : {},
      body: bodyStr,
      bodyRawB64: rawB64,
    });
  };

  globalThis.__lx_js_call__ = function (action, dataJson) {
    const data = dataJson == null ? null : JSON.parse(dataJson);
    switch (action) {
      case 'request': return handleRequest(data);
      case 'response': return handleNativeResponse(data);
      case '__set_timeout__': return globalThis.__lx_timer_fire__(data);
      case '__run_error__': return undefined;
    }
    return undefined;
  };

  // ---- generic async bridge primitives (shared with SDK) -----------------
  globalThis.__bridge__ = {
    setTimeout(callback, timeout) {
      if (typeof callback !== 'function') throw new Error('callback required a function');
      const id = ++timerSeq;
      pendingTimers[id] = callback;
      nativeSync('timer', { id: id, ms: parseInt(timeout) || 0 });
      return id;
    },
    clearTimeout(id) { delete pendingTimers[id]; },
    http(url, options) {
      return new Promise(function (resolve, reject) {
        const id = ++reqSeq;
        httpPendings[id] = { resolve: resolve, reject: reject };
        nativeSync('http', { id: id, url: url, options: options });
      });
    },
    md5: (s) => nativeSync('md5', s),
    sha1: (s) => nativeSync('sha1', s),
    aes: (obj) => nativeSync('aes', obj),
    rsa: (obj) => nativeSync('rsa', obj),
    str2b64: (s) => nativeSync('str2b64', s),
    b642buf: (s) => nativeSync('b642buf', s),
    inflate: (b64) => nativeSync('inflate', { data: b64 }),
    deflate: (b64) => nativeSync('deflate', { data: b64 }),
    gbk2str: (b64) => nativeSync('gbk', { data: b64 }),
    randomBytesJs: function (size) {
      const a = new Uint8Array(size);
      for (let i = 0; i < size; i++) a[i] = Math.floor(Math.random() * 256);
      return a;
    },
  };

  // ---- byte/string helpers (ported from lx preload) ----------------------
  function bytesToString(bytes) {
    let result = '';
    let i = 0;
    while (i < bytes.length) {
      const byte = bytes[i];
      if (byte < 128) { result += String.fromCharCode(byte); i++; }
      else if (byte >= 192 && byte < 224) {
        result += String.fromCharCode(((byte & 31) << 6) | (bytes[i + 1] & 63)); i += 2;
      } else {
        result += String.fromCharCode(((byte & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63)); i += 3;
      }
    }
    return result;
  }
  function stringToBytes(str) {
    const bytes = [];
    for (let i = 0; i < str.length; i++) {
      const c = str.charCodeAt(i);
      if (c < 128) bytes.push(c);
      else if (c < 2048) { bytes.push((c >> 6) | 192); bytes.push((c & 63) | 128); }
      else { bytes.push((c >> 12) | 224); bytes.push(((c >> 6) & 63) | 128); bytes.push((c & 63) | 128); }
    }
    return bytes;
  }
  function b64encodeBytes(bytes) { return globalThis.__bridge__.str2b64(bytesToString(bytes)); }
  function b64decodeToBytes(b64) { return new Uint8Array(JSON.parse(globalThis.__bridge__.b642buf(b64))); }
  function bytesToB64Json(bytes) { return JSON.stringify(Array.from(bytes)); }
  function hexToBytes(hex) {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
    return out;
  }

  // ---- lx protocol (as seen by user-imported source scripts) -------------
  let isInited = false;
  let showedUpdateAlert = false;
  const requestQueue = {}; // requestKey -> {abort fn placeholder, callback}

  const NATIVE_ACTION = { init: 'init', showUpdateAlert: 'showUpdateAlert', request: 'request', response: 'response', cancelRequest: 'cancelRequest' };

  const allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local'];
  const supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: [],
  };
  const supportActions = {
    kw: ['musicUrl'], kg: ['musicUrl'], tx: ['musicUrl'], wy: ['musicUrl'],
    mg: ['musicUrl'], xm: ['musicUrl'],
    local: ['musicUrl', 'lyric', 'pic'],
  };

  function verifyLyricInfo(info) {
    if (typeof info != 'object' || typeof info.lyric != 'string') throw new Error('failed');
    if (info.lyric.length > 51200) throw new Error('failed');
    return {
      lyric: info.lyric,
      tlyric: (typeof info.tlyric == 'string' && info.tlyric.length < 5120) ? info.tlyric : null,
      rlyric: (typeof info.rlyric == 'string' && info.rlyric.length < 5120) ? info.rlyric : null,
      lxlyric: (typeof info.lxlyric == 'string' && info.lxlyric.length < 8192) ? info.lxlyric : null,
    };
  }

  const events = { request: null };

  function nativeCall(action, data) {
    return nativeSync(action, data);
  }

  function sendNativeRequest(url, options, callback) {
    const requestKey = '' + (Math.random());
    const info = { aborted: false, abort: function () { nativeCall('cancelRequest', requestKey); } };
    requestQueue[requestKey] = { callback: callback, requestInfo: info };
    nativeCall('request', { requestKey: requestKey, url: url, options: options });
    return info;
  }

  function handleNativeResponse(d) {
    const t = requestQueue[d.requestKey];
    if (!t) return;
    delete requestQueue[d.requestKey];
    t.requestInfo.aborted = true;
    if (d.error == null) t.callback(null, d.response);
    else t.callback(new Error(d.error), null);
  }

  function handleRequest(d) {
    if (!events.request) return nativeCall('response', { requestKey: d.requestKey, status: false, errorMessage: 'Request event is not defined' });
    try {
      events.request.call(globalThis.lx, { source: d.source, action: d.action, info: d.info }).then(function (response) {
        let result;
        switch (d.action) {
          case 'musicUrl':
            if (typeof response != 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed');
            result = { source: d.source, action: d.action, data: { type: d.info.type, url: response } };
            break;
          case 'lyric':
            result = { source: d.source, action: d.action, data: verifyLyricInfo(response) };
            break;
          case 'pic':
            if (typeof response != 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed');
            result = { source: d.source, action: d.action, data: response };
            break;
        }
        nativeCall('response', { requestKey: d.requestKey, status: true, result: result });
      }).catch(function (err) {
        nativeCall('response', { requestKey: d.requestKey, status: false, errorMessage: err.message });
      });
    } catch (err) {
      nativeCall('response', { requestKey: d.requestKey, status: false, errorMessage: err.message });
    }
  }

  function handleInit(info) {
    if (!info) { nativeCall('init', { info: null, status: false, errorMessage: 'Missing required parameter init info' }); return; }
    const sourceInfo = { sources: {} };
    try {
      for (const source of allSources) {
        const userSource = info.sources[source];
        if (!userSource || userSource.type !== 'music') continue;
        sourceInfo.sources[source] = {
          type: 'music',
          actions: (supportActions[source] || []).filter(a => (userSource.actions || []).includes(a)),
          qualitys: (supportQualitys[source] || []).filter(q => (userSource.qualitys || []).includes(q)),
        };
      }
    } catch (error) {
      nativeCall('init', { info: null, status: false, errorMessage: error.message });
      return;
    }
    nativeCall('init', { info: sourceInfo, status: true });
  }

  const utils = {
    crypto: {
      aesEncrypt(buffer, mode, key, iv) {
        const b64 = (data) => typeof data === 'string' ? globalThis.__bridge__.str2b64(data) : b64encodeBytes(Array.from(data));
        switch (mode) {
          case 'aes-128-cbc': return b64decodeToBytes(globalThis.__bridge__.aes({ data: b64(buffer), mode: 'CBC_128_PKCS7Padding', key: b64(key), iv: b64(iv) }));
          case 'aes-128-ecb': return b64decodeToBytes(globalThis.__bridge__.aes({ data: b64(buffer), mode: 'ECB_128_NoPadding', key: b64(key), iv: '' }));
          default: throw new Error('Binary encoding is not supported for input strings: ' + mode);
        }
      },
      rsaEncrypt(buffer, key) {
        if (typeof key !== 'string') throw new Error('Invalid RSA key');
        key = key.replace('-----BEGIN PUBLIC KEY-----', '').replace('-----END PUBLIC KEY-----', '');
        const b64in = (typeof buffer === 'string') ? globalThis.__bridge__.str2b64(buffer) : b64encodeBytes(Array.from(buffer));
        return b64decodeToBytes(globalThis.__bridge__.rsa({ data: b64in, key: key, padding: 'NoPadding' }));
      },
      randomBytes(size) { return globalThis.__bridge__.randomBytesJs(size); },
      md5(str) { if (typeof str !== 'string') throw new Error('param required a string'); return globalThis.__bridge__.md5(encodeURIComponent(str)); },
    },
    buffer: {
      from(input, encoding) {
        if (typeof input === 'string') {
          switch (encoding) {
            case 'binary': throw new Error('Binary encoding is not supported for input strings');
            case 'base64': return b64decodeToBytes(input);
            case 'hex': return hexToBytes(input);
            default: return new Uint8Array(stringToBytes(input));
          }
        } else if (Array.isArray(input)) { return new Uint8Array(input); }
        throw new Error('Unsupported input type: ' + input + ' encoding: ' + encoding);
      },
      bufToString(buf, format) {
        if (Array.isArray(buf) || ArrayBuffer.isView(buf)) {
          switch (format) {
            case 'binary': return buf;
            case 'hex': return Array.from(new Uint8Array(buf)).reduce((s, b) => s + b.toString(16).padStart(2, '0'), '');
            case 'base64': return globalThis.__bridge__.str2b64(bytesToString(Array.from(buf)));
            default: return bytesToString(Array.from(buf));
          }
        }
        throw new Error('Input is not a valid buffer: ' + buf + ' format: ' + format);
      },
    },
    zlib: {
      inflate(buf) { return Promise.resolve(new Uint8Array(JSON.parse(globalThis.__bridge__.inflate(b64encodeBytes(Array.from(buf)))))); },
      deflate(buf) { return Promise.resolve(new Uint8Array(JSON.parse(globalThis.__bridge__.deflate(b64encodeBytes(Array.from(buf)))))); },
    },
  };

  globalThis.lx_setup = function (key, name, description, version, author, homepage, rawScript) {
    delete globalThis.lx_setup;

    globalThis.lx = {
      EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
      request(url, options, callback) {
        let req = sendNativeRequest(url, options, function (err, resp) {
          if (err) return callback(err, null, null);
          callback(err, {
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            headers: resp.headers,
            body: resp.body,
          }, resp.body);
        });
        return function () { if (req) { req.abort(); req = null; } };
      },
      send(eventName, data) {
        return new Promise(function (resolve, reject) {
          if (eventName === 'inited') {
            if (isInited) return reject(new Error('Script is inited'));
            isInited = true;
            handleInit(data);
            resolve();
          } else if (eventName === 'updateAlert') {
            if (showedUpdateAlert) return reject(new Error('The update alert can only be called once.'));
            showedUpdateAlert = true;
            nativeCall('showUpdateAlert', { log: data && data.log, updateUrl: data && data.updateUrl, name: name });
            resolve();
          } else reject(new Error('Unknown event name: ' + eventName));
        });
      },
      on(eventName, handler) {
        if (eventName === 'request') { events.request = handler; return Promise.resolve(); }
        return Promise.reject(new Error('The event is not supported: ' + eventName));
      },
      utils: utils,
      currentScriptInfo: { name: name, description: description, version: version, author: author, homepage: homepage, rawScript: rawScript },
      version: '2.0.0',
      env: 'mobile',
    };
    // keep references for Dart-side response injection
    globalThis.__lx_pending_req__ = requestQueue;
  };

  // fallback setTimeout in case Dart does not drive timers
  if (!globalThis.setTimeout) globalThis.setTimeout = function (cb, ms) { return globalThis.__bridge__.setTimeout(cb, ms); };
  if (!globalThis.clearTimeout) globalThis.clearTimeout = function (id) { globalThis.__bridge__.clearTimeout(id); };
})();
