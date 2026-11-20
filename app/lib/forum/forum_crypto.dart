// The RSA half of Discourse User API Keys. The app makes a key pair, sends the
// public key (PEM, SubjectPublicKeyInfo) to `/user-api-key/new`, and Discourse
// returns the new API key encrypted with it: Ruby
// `public_key.encrypt(json, rsa_padding_mode: oaep|pkcs1)`, then
// `Base64.encode64` (line breaks every 60 characters). OAEP is OpenSSL's
// default flavour: SHA-1 for the hash and MGF1. Servers that predate the
// `padding` parameter ignore it and use PKCS#1 v1.5, so both are accepted.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// An RSA key pair for one install.
class ForumKeyPair {
  const ForumKeyPair({
    required this.modulus,
    required this.publicExponent,
    required this.privateExponent,
    required this.p,
    required this.q,
  });

  final BigInt modulus;
  final BigInt publicExponent;
  final BigInt privateExponent;
  final BigInt p;
  final BigInt q;

  RSAPrivateKey get privateKey => RSAPrivateKey(modulus, privateExponent, p, q);
  RSAPublicKey get publicKey => RSAPublicKey(modulus, publicExponent);

  /// Size in bits.
  int get bits => modulus.bitLength;

  Map<String, String> toJson() => {
    'n': modulus.toRadixString(16),
    'e': publicExponent.toRadixString(16),
    'd': privateExponent.toRadixString(16),
    'p': p.toRadixString(16),
    'q': q.toRadixString(16),
  };

  static ForumKeyPair? fromJson(Object? json) {
    if (json is! Map) return null;
    BigInt? big(String key) => json[key] is String ? BigInt.tryParse(json[key] as String, radix: 16) : null;
    final n = big('n');
    final e = big('e');
    final d = big('d');
    final p = big('p');
    final q = big('q');
    if (n == null || e == null || d == null || p == null || q == null) return null;
    return ForumKeyPair(modulus: n, publicExponent: e, privateExponent: d, p: p, q: q);
  }

  /// The public key as `-----BEGIN PUBLIC KEY-----` PEM.
  String get publicPem => _pem('PUBLIC KEY', subjectPublicKeyInfo(modulus, publicExponent));
}

/// A fresh 2048-bit key pair. Takes a second or two on a phone, so it runs
/// on a background isolate.
Future<ForumKeyPair> generateForumKeyPair({int bits = 2048}) => Isolate.run(() => generateForumKeyPairSync(bits: bits));

ForumKeyPair generateForumKeyPairSync({int bits = 2048}) {
  final random = FortunaRandom()..seed(KeyParameter(secureBytes(32)));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64), random));
  final pair = generator.generateKeyPair();
  final public = pair.publicKey;
  final private = pair.privateKey;
  return ForumKeyPair(
    modulus: public.modulus!,
    publicExponent: public.publicExponent!,
    privateExponent: private.privateExponent!,
    p: private.p!,
    q: private.q!,
  );
}

Uint8List secureBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList([for (var i = 0; i < length; i++) random.nextInt(256)]);
}

/// [length] random bytes as lowercase hex.
String randomHex(int length) => secureBytes(length).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Decrypts Discourse's `payload` (base64, line breaks allowed): OAEP first,
/// PKCS#1 v1.5 when that fails. Throws [FormatException] when neither works.
Uint8List decryptForumPayload(String payload, ForumKeyPair keys) {
  final Uint8List cipher;
  try {
    cipher = base64.decode(payload.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw const FormatException('payload is not base64');
  }
  for (final engine in [OAEPEncoding(RSAEngine()), PKCS1Encoding(RSAEngine())]) {
    try {
      engine.init(false, PrivateKeyParameter<RSAPrivateKey>(keys.privateKey));
      return engine.process(cipher);
    } catch (_) {
      // Wrong padding: try the next one.
    }
  }
  throw const FormatException('payload does not decrypt with this key');
}

/// Encrypts like Discourse does (tests, previews).
Uint8List encryptForumPayload(List<int> data, ForumKeyPair keys, {bool oaep = true}) {
  final engine = oaep ? OAEPEncoding(RSAEngine()) : PKCS1Encoding(RSAEngine());
  engine.init(true, PublicKeyParameter<RSAPublicKey>(keys.publicKey));
  return engine.process(Uint8List.fromList(data));
}

// ── DER / PEM (just enough for an RSA SubjectPublicKeyInfo) ─────────────────

/// DER of `SubjectPublicKeyInfo { rsaEncryption, RSAPublicKey { n, e } }`.
Uint8List subjectPublicKeyInfo(BigInt modulus, BigInt exponent) {
  final rsaPublicKey = _der(0x30, [..._integer(modulus), ..._integer(exponent)]);
  final algorithm = _der(0x30, [
    ..._der(0x06, const [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), // 1.2.840.113549.1.1.1
    0x05, 0x00, // NULL
  ]);
  final bitString = _der(0x03, [0x00, ...rsaPublicKey]);
  return Uint8List.fromList(_der(0x30, [...algorithm, ...bitString]));
}

List<int> _integer(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _der(0x02, bytes);
}

List<int> _der(int tag, List<int> content) => [tag, ..._length(content.length), ...content];

List<int> _length(int length) {
  if (length < 0x80) return [length];
  final bytes = <int>[];
  for (var n = length; n > 0; n >>= 8) {
    bytes.insert(0, n & 0xFF);
  }
  return [0x80 | bytes.length, ...bytes];
}

String _pem(String label, List<int> der) {
  final b64 = base64.encode(der);
  final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}
