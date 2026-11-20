// What of a namespace's user layer may leave the device in a profile share.
// Credentials never do: schema `secret` fields (the Host never returns them
// anyway), anything that looks like a key or token, URLs with credentials in
// them. Credential *reference* fields (`credential-ref`, `apiKeyEnv`-style
// names) stay — they name a credential, they don't hold one. Absolute local
// paths are dropped: they mean nothing on the receiving machine.

import 'package:dsh_client/dsh_client.dart';

import '../ui/chat/secret_mask.dart' show findSecrets;

/// Namespaces bound to an account, a machine or telemetry: never offered.
final _deniedNamespace = RegExp(
  r'(account|credential|telemetry|analytics|anonymous|remote-access|remotes|webserver|gateway|otel|login|auth)',
  caseSensitive: false,
);

/// Last words of a field name that holds a secret (`accessToken`,
/// `client_secret`, `X-Api-Key`); `maxTokens`, `apiKeyEnv`, `keyId` are not.
const _secretWords = {'token', 'secret', 'password', 'passwd', 'passphrase', 'cookie', 'authorization', 'apikey'};
const _keyQualifiers = {'api', 'private', 'secret', 'access', 'client', 'session', 'signing', 'license'};

/// Whether a field called [key] holds a secret.
bool isSecretFieldName(String key) {
  final words = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .split(RegExp(r'[\s_\-.]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.toLowerCase())
      .toList();
  if (words.isEmpty) return false;
  final last = words.last;
  if (_secretWords.contains(last)) return true;
  if (last == 'key') return words.length == 1 || _keyQualifiers.contains(words[words.length - 2]);
  return false;
}

final _absolutePath = RegExp(r'^(/|~/|~$|[A-Za-z]:[\\/]|\\\\|file:)');
final _longOpaque = RegExp(r'^[A-Za-z0-9+/_=.-]{40,}$');
final _secretQuery = RegExp(
  r'^(token|key|secret|sig|signature|password|access_token|auth|api_key|apikey)$',
  caseSensitive: false,
);

/// Whether [ns] may be offered at all.
bool isShareableNamespace(String ns) => !_deniedNamespace.hasMatch(ns);

/// Whether a text file contains a recognizable credential.
bool containsSecret(String text) => findSecrets(text).isNotEmpty;

/// Whether a string value must not be shared.
bool isUnshareableString(String value) {
  final v = value.trim();
  if (v.isEmpty) return false;
  if (_absolutePath.hasMatch(v)) return true;
  if (findSecrets(v).isNotEmpty) return true;
  if (RegExp(r'^bearer\s', caseSensitive: false).hasMatch(v)) return true;
  // Long opaque strings with letters and digits mixed: likely a key.
  if (_longOpaque.hasMatch(v) && RegExp(r'\d').hasMatch(v) && RegExp(r'[A-Za-z]').hasMatch(v) && !v.contains('.')) {
    return true;
  }
  final uri = Uri.tryParse(v);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    if (uri.userInfo.isNotEmpty) return true;
    try {
      if (uri.queryParameters.keys.any(_secretQuery.hasMatch)) return true;
    } on FormatException {
      return true;
    }
  }
  return false;
}

/// The user layer of one namespace, cleaned for sharing.
class SanitizedSection {
  const SanitizedSection(this.ns, this.values, {this.dropped = 0});

  final String ns;

  /// Top-level field → value; empty when nothing shareable is left.
  final Map<String, Object?> values;

  /// Fields (at any depth) that were left out.
  final int dropped;

  bool get isEmpty => values.isEmpty;
}

/// Cleans [view]'s user layer. Null when the namespace is never shared.
SanitizedSection? sanitizeNamespace(SettingsNamespaceView view) {
  if (!isShareableNamespace(view.ns)) return null;
  final user = view.user;
  if (user == null || user.isEmpty) return SanitizedSection(view.ns, const {});
  final secretPaths = {for (final s in view.secrets) s.path.join('\u0000')};
  var dropped = 0;

  Object? clean(Object? value, SchemaNode? schema, List<String> path, String? key) {
    final node = schema?.effective;
    if (node != null && node.isSecret) return _drop;
    if (secretPaths.contains(path.join('\u0000'))) return _drop;
    final isRef = node?.isCredentialRef ?? false;
    if (key != null && !isRef && isSecretFieldName(key)) return _drop;
    switch (value) {
      case String s:
        if (isRef) return _absolutePath.hasMatch(s.trim()) ? _drop : s;
        return isUnshareableString(s) ? _drop : s;
      case Map<Object?, Object?> m:
        final out = <String, Object?>{};
        var removed = 0;
        for (final MapEntry(key: k, value: v) in m.entries) {
          if (k is! String) continue;
          final childSchema = node?.fields?[k] ?? (node?.type == 'dict' ? node?.inner : null);
          final cleaned = clean(v, childSchema, [...path, k], k);
          if (identical(cleaned, _drop)) {
            removed++;
            dropped++;
          } else {
            out[k] = cleaned;
          }
        }
        // A map emptied by removals says nothing useful.
        return out.isEmpty && removed > 0 ? _drop : out;
      case List<Object?> l:
        final out = <Object?>[];
        for (var i = 0; i < l.length; i++) {
          final cleaned = clean(l[i], node?.inner, [...path, '$i'], null);
          if (identical(cleaned, _drop)) {
            dropped++;
          } else {
            out.add(cleaned);
          }
        }
        return out.isEmpty && l.isNotEmpty ? _drop : out;
      default:
        return value;
    }
  }

  final values = <String, Object?>{};
  final fields = view.schema.fields;
  for (final MapEntry(:key, :value) in user.entries) {
    final cleaned = clean(value, fields?[key], [key], key);
    if (identical(cleaned, _drop)) {
      dropped++;
    } else {
      values[key] = cleaned;
    }
  }
  return SanitizedSection(view.ns, values, dropped: dropped);
}

const Object _drop = _Dropped();

class _Dropped {
  const _Dropped();
}
