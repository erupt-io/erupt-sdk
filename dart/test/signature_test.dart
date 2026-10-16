import 'dart:convert';
import 'dart:io';

import 'package:erupt_sdk/erupt_sdk.dart';
import 'package:erupt_sdk/src/signature.dart' show hex, sha256;
import 'package:test/test.dart';

void main() {
  test('SHA-256 of the FIPS examples', () {
    expect(hex(sha256(utf8.encode(''))), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(hex(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(hex(sha256(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    // a message that fills a block up to the length field, and one longer than a block
    expect(hex(sha256(List.filled(56, 0x61))), 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
    expect(hex(sha256(List.filled(1000, 0x61))), '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
  });

  test('agrees with the Java vectors', () {
    final doc = jsonDecode(File('../conformance/signature-vectors.json').readAsStringSync()) as Map<String, dynamic>;
    final token = doc['accessToken'] as String;
    for (final v in (doc['vectors'] as List).cast<Map<String, dynamic>>()) {
      final body = v['body'] == null ? null : utf8.encode(v['body'] as String);
      final signed = Signature.sign(token, v['method'] as String, v['pathAndQuery'] as String, v['timestamp'] as int,
          v['enforced'] as String?, v['user'] as String?, body);
      expect(signed, v['signature'], reason: v['case'] as String);
      final ts = '${v['timestamp']}';
      expect(
          Signature.verify(token, v['method'] as String, v['pathAndQuery'] as String, ts, v['enforced'] as String?,
              v['user'] as String?, body, signed, v['timestamp'] as int),
          isTrue);
    }
  });

  test('rejects an illegal or stale timestamp and a wrong signature', () {
    final sig = Signature.sign('k', 'GET', '/x', 1000, null, null, const []);
    expect(Signature.verify('k', 'GET', '/x', '1000', null, null, const [], sig, 1300), isTrue);
    expect(Signature.verify('k', 'GET', '/x', '1000', null, null, const [], sig, 1301), isFalse);
    expect(Signature.verify('k', 'GET', '/x', 'soon', null, null, const [], sig, 1000), isFalse);
    expect(Signature.verify('k', 'GET', '/x', '1000', null, null, const [], '00$sig', 1000), isFalse);
    expect(Signature.verify('other', 'GET', '/x', '1000', null, null, const [], sig, 1000), isFalse);
  });
}
