import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;
import 'package:pointycastle/asymmetric/api.dart' as pca;
import 'package:asn1lib/asn1lib.dart';

/// Synchronous native helpers exposed to the JS engine (md5/sha1/aes/rsa/base64/zlib/gbk).
class NativeFuncs {
  static String md5(String s) => c.md5.convert(utf8.encode(s)).toString();
  static String sha1(String s) => c.sha1.convert(utf8.encode(s)).toString();

  static String str2b64(String s) => base64.encode(utf8.encode(s));

  /// returns JSON array of byte values (matches lx utils_b642buf)
  static String b642buf(String b64) => jsonEncode(base64.decode(b64));

  static String b642str(String b64) => utf8.decode(base64.decode(b64), allowMalformed: true);

  static String aes(Map args) {
    final data = base64.decode(args['data'] as String);
    final key = base64.decode(args['key'] as String);
    final iv = args['iv'] != null && (args['iv'] as String).isNotEmpty ? base64.decode(args['iv'] as String) : List<int>.filled(16, 0);
    final mode = args['mode'] as String;
    // Use bare engine for per-block operation
    final aes = pc.AESEngine();
    aes.init(true, pc.KeyParameter(key));
    final List<int> input;
    if (mode == 'CBC_128_PKCS7Padding') {
      input = _pkcs7Pad(data);
    } else {
      input = List<int>.from(data);
      while (input.length % 16 != 0) {
        input.add(0);
      }
    }
    final out = List<int>.filled(input.length, 0);
    if (mode == 'CBC_128_PKCS7Padding') {
      var prev = List<int>.from(iv.take(16));
      for (var off = 0; off < input.length; off += 16) {
        final block = List<int>.generate(16, (i) => input[off + i] ^ prev[i]);
        final enc = Uint8List(16);
        aes.processBlock(Uint8List.fromList(block), 0, enc, 0);
        out.setRange(off, off + 16, enc);
        prev = enc;
      }
    } else {
      for (var off = 0; off < input.length; off += 16) {
        final enc = Uint8List(16);
        aes.processBlock(Uint8List.fromList(input.sublist(off, off + 16)), 0, enc, 0);
        out.setRange(off, off + 16, enc);
      }
    }
    return base64.encode(out);
  }

  static String rsa(Map args) {
    // raw RSA public operation over an already-padded block (lx "NoPadding")
    final data = base64.decode(args['data'] as String);
    final keyPemBody = (args['key'] as String).replaceAll(RegExp(r'\s'), '');
    final der = base64.decode(keyPemBody);
    final pubKey = _parseSpkiPublicKey(der);
    final engine = pc.RSAEngine();
    engine.init(true, pc.PublicKeyParameter<pca.RSAPublicKey>(pubKey));
    final out = engine.process(Uint8List.fromList(data));
    return base64.encode(out);
  }

  static pca.RSAPublicKey _parseSpkiPublicKey(Uint8List der) {
    final outer = ASN1Parser(der).nextObject() as ASN1Sequence;
    final bitStr = outer.elements[1] as ASN1BitString;
    final inner = ASN1Parser(bitStr.contentBytes()).nextObject() as ASN1Sequence;
    final n = (inner.elements[0] as ASN1Integer).valueAsBigInteger;
    final e = (inner.elements[1] as ASN1Integer).valueAsBigInteger;
    return pca.RSAPublicKey(n, e);
  }

  static String inflate(Map args) {
    final data = base64.decode(args['data'] as String);
    try {
      return base64.encode(ZLibCodec(raw: true).decode(data));
    } catch (_) {
      return base64.encode(ZLibCodec().decode(data));
    }
  }

  static String deflate(Map args) {
    final data = base64.decode(args['data'] as String);
    return base64.encode(ZLibEncoder().convert(data));
  }

  static List<int> _pkcs7Pad(List<int> data) {
    final padLen = 16 - (data.length % 16);
    return [...data, ...List<int>.filled(padLen, padLen)];
  }
}
