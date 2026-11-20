import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:flutter_test/flutter_test.dart';

final _fixtures = '${Directory.current.path}/test/share_hosted/fixtures';

Uint8List _b64(String s) => base64.decode(s);

void main() {
  group('WebCrypto interop', () {
    // Made by node's crypto.subtle (fixtures/make_vectors.mjs), the API the
    // web viewer decrypts with.
    final vectors = (jsonDecode(File('$_fixtures/webcrypto_vectors.json').readAsStringSync())['vectors'] as List)
        .cast<Map<String, Object?>>();

    for (final v in vectors) {
      test('${v['name']}: same bytes as WebCrypto, and opens', () {
        final key = decodeHostedKey(v['key']! as String)!;
        final blob = _b64(v['blob']! as String);
        final sealed = sealHostedRaw(_b64(v['gzip']! as String), key, _b64(v['iv']! as String));
        expect(sealed, blob);
        expect(utf8.decode(openHosted(blob, key)), v['text']);
      });
    }

    test('what the app seals, WebCrypto and the viewer open', () async {
      final node = await Process.run('node', ['--version']).then((r) => r.exitCode == 0, onError: (_) => false);
      if (!node) {
        markTestSkipped('node is not installed');
        return;
      }
      final text = vectors.last['text']! as String;
      final key = newHostedKey();
      final dir = await Directory.systemTemp.createTemp('hosted-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/blob')..writeAsBytesSync(sealHosted(utf8.encode(text), key));
      final result = await Process.run('node', ['$_fixtures/open_blob.mjs', file.path, encodeHostedKey(key)]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final out = jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(out['text'], text);
      if (out['viewer'] != null) expect(out['viewer'], text);
    });
  });

  group('seal and open', () {
    test('round trip, with a fresh IV each time', () {
      final key = newHostedKey();
      final file = utf8.encode('{"dshgo":2,"kind":"conversation","name":"测试"}');
      final a = sealHosted(file, key);
      final b = sealHosted(file, key);
      expect(a.sublist(0, 4), hostedMagic);
      expect(a.sublist(4, 16), isNot(b.sublist(4, 16)));
      expect(openHosted(a, key), file);
      expect(openHosted(b, key), file);
    });

    test('refuses a wrong key, a tampered blob and foreign bytes', () {
      final key = newHostedKey();
      final blob = sealHosted(utf8.encode('secret'), key);
      expect(() => openHosted(blob, newHostedKey()), throwsA(isA<HostedFormatException>()));
      final tampered = Uint8List.fromList(blob)..[20] ^= 1;
      expect(() => openHosted(tampered, key), throwsA(isA<HostedFormatException>()));
      final foreign = Uint8List.fromList(blob)..[0] = 0x7b;
      expect(() => openHosted(foreign, key), throwsA(isA<HostedFormatException>()));
      expect(() => openHosted(Uint8List(20), key), throwsA(isA<HostedFormatException>()));
      expect(() => openHosted(blob, Uint8List(16)), throwsA(isA<HostedFormatException>()));
    });

    test('a gzip bomb stops at the cap', () {
      final key = newHostedKey();
      final iv = Uint8List(12);
      // 65 MB of zeros gzips to ~64 KB.
      final bomb = Uint8List.fromList(gzip.encode(Uint8List(hostedMaxPlainBytes + 1024 * 1024)));
      final blob = sealHostedRaw(bomb, key, iv);
      expect(() => openHosted(blob, key), throwsA(isA<HostedFormatException>()));
    });

    test('a few MB seal and open in reasonable time', () {
      final key = newHostedKey();
      // Base64 of pictures dominates big conversations: barely compressible.
      final random = Random(7);
      final file = utf8.encode(base64.encode(List.generate(3 * 1024 * 1024, (_) => random.nextInt(256))));
      final watch = Stopwatch()..start();
      final blob = sealHosted(file, key);
      final sealMs = watch.elapsedMilliseconds;
      expect(openHosted(blob, key).length, file.length);
      // ignore: avoid_print
      print(
        'seal ${file.length >> 10} KiB (${blob.length >> 10} KiB sealed): $sealMs ms, open: ${watch.elapsedMilliseconds - sealMs} ms (JIT)',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    });
  });

  group('keys and links', () {
    test('keys are 32 bytes as 43 base64url characters', () {
      final key = newHostedKey();
      final text = encodeHostedKey(key);
      expect(text, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(decodeHostedKey(text), key);
      expect(decodeHostedKey('${text}A'), isNull);
      expect(decodeHostedKey(text.replaceRange(0, 1, '+')), isNull);
      expect(decodeHostedKey(''), isNull);
    });

    test('parses hosted links', () {
      final key = encodeHostedKey(newHostedKey());
      final ref = parseHostedUrl('https://go.dshtui.com/c/Ab3dE5gH9k#k=$key')!;
      expect(ref.origin, 'https://go.dshtui.com');
      expect(ref.id, 'Ab3dE5gH9k');
      expect(ref.key, key);
      expect(parseHostedUrl('https://go.dshtui.com/c/Ab3dE5gH9k/#k=$key')?.id, 'Ab3dE5gH9k');
      expect(parseHostedUrl('https://go.dshtui.com/c/Ab3dE5gH9k#k=$key', origin: 'https://s.dshtui.com'), isNull);
      expect(parseHostedUrl('https://go.dshtui.com/c/Ab3dE5gH9k'), isNull);
      expect(parseHostedUrl('http://go.dshtui.com/c/Ab3dE5gH9k#k=$key'), isNull);
      expect(parseHostedUrl('https://go.dshtui.com/c/short#k=$key'), isNull);
      expect(parseHostedUrl('https://go.dshtui.com/share/#k=$key'), isNull);
    });
  });
}
