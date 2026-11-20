// End-to-end encryption of hosted conversation links
// (docs/design/share-links.md).
//
//   blob = "DSG1" ‖ IV (12 bytes) ‖ AES-256-GCM(gzip(file), no AAD) incl. 16-byte tag
//
// The key is 32 random bytes, carried as base64url (no padding) after `#k=`
// in the link. Pure Dart (package:cryptography's Dart implementation, as
// packages/dsh_remote uses), so it runs the same in tests and isolates; the
// web viewer decrypts the same bytes with WebCrypto (site/share/viewer.js).

import 'dart:convert';
import 'dart:io' show gzip, GZipCodec;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretBoxAuthenticationError, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;

const hostedMagic = [0x44, 0x53, 0x47, 0x31]; // "DSG1"
const hostedIvLength = 12;
const hostedTagLength = 16;
const hostedKeyLength = 32;

/// Largest file a blob may unpack to (a guard against gzip bombs).
const hostedMaxPlainBytes = 64 * 1024 * 1024;

/// The blob isn't ours, or the key doesn't open it.
class HostedFormatException implements Exception {
  const HostedFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'HostedFormatException: $reason';
}

final _random = Random.secure();

Uint8List _randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

/// A fresh 32-byte key.
Uint8List newHostedKey() => _randomBytes(hostedKeyLength);

/// base64url without padding, as the link carries it.
String encodeHostedKey(List<int> key) => base64Url.encode(key).replaceAll('=', '');

/// The key from a link's `#k=`; null when it isn't 32 bytes of base64url.
Uint8List? decodeHostedKey(String text) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text)) return null;
  try {
    final bytes = base64Url.decode('$text=');
    return bytes.length == hostedKeyLength ? Uint8List.fromList(bytes) : null;
  } on FormatException {
    return null;
  }
}

final _aes = DartAesGcm.with256bits();

/// AES-256-GCM of [plain] with [key] and [iv], framed as a blob. The layer
/// below [sealHosted], for test vectors.
Uint8List sealHostedRaw(Uint8List plain, Uint8List key, Uint8List iv) {
  if (key.length != hostedKeyLength) throw ArgumentError('key must be 32 bytes');
  if (iv.length != hostedIvLength) throw ArgumentError('iv must be 12 bytes');
  final box = _aes.encryptSync(plain, secretKeyData: SecretKeyData(key), nonce: iv);
  final head = hostedMagic.length + hostedIvLength;
  return Uint8List(head + box.cipherText.length + hostedTagLength)
    ..setAll(0, hostedMagic)
    ..setAll(hostedMagic.length, iv)
    ..setAll(head, box.cipherText)
    ..setAll(head + box.cipherText.length, box.mac.bytes);
}

/// The gzipped plaintext inside [blob].
Uint8List openHostedRaw(Uint8List blob, Uint8List key) {
  const head = 4 + hostedIvLength;
  if (blob.length < head + hostedTagLength) throw const HostedFormatException('short');
  for (var i = 0; i < hostedMagic.length; i++) {
    if (blob[i] != hostedMagic[i]) throw const HostedFormatException('magic');
  }
  if (key.length != hostedKeyLength) throw const HostedFormatException('key');
  final box = SecretBox(
    Uint8List.sublistView(blob, head, blob.length - hostedTagLength),
    nonce: Uint8List.sublistView(blob, 4, head),
    mac: Mac(Uint8List.sublistView(blob, blob.length - hostedTagLength)),
  );
  try {
    return Uint8List.fromList(_aes.decryptSync(box, secretKeyData: SecretKeyData(key)));
  } on SecretBoxAuthenticationError {
    throw const HostedFormatException('key');
  }
}

/// gzip, then encrypt: what goes to the share host. [iv] is random unless a
/// test pins it.
Uint8List sealHosted(List<int> file, Uint8List key, {Uint8List? iv}) =>
    sealHostedRaw(Uint8List.fromList(gzip.encode(file)), key, iv ?? _randomBytes(hostedIvLength));

/// The file bytes inside [blob] (decrypt, then gunzip).
Uint8List openHosted(Uint8List blob, Uint8List key) {
  final packed = openHostedRaw(blob, key);
  final out = BytesBuilder(copy: false);
  final sink = ByteConversionSink.withCallback((chunk) => out.add(chunk));
  final inflate = GZipCodec().decoder.startChunkedConversion(_CappedSink(sink, hostedMaxPlainBytes));
  try {
    const step = 64 * 1024;
    for (var at = 0; at < packed.length; at += step) {
      inflate.add(Uint8List.sublistView(packed, at, min(at + step, packed.length)));
    }
    inflate.close();
  } on HostedFormatException {
    rethrow;
  } catch (_) {
    throw const HostedFormatException('gzip');
  }
  return out.takeBytes();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this._inner, this._limit);
  final ByteConversionSink _inner;
  final int _limit;
  int _total = 0;

  @override
  void add(List<int> data) {
    _total += data.length;
    if (_total > _limit) throw const HostedFormatException('too large');
    _inner.add(data);
  }

  @override
  void close() => _inner.close();
}
