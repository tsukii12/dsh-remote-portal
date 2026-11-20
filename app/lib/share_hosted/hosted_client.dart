// The share host's API (services/share-worker, docs/design/share-links.md).
// Everything is encrypted here before it leaves the phone; the host only
// stores ciphertext.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import 'hosted_config.dart';
import 'hosted_crypto.dart';
import 'hosted_link.dart';

enum HostedShareError { network, tooLarge, rateLimited, rejected, unavailable, gone, forbidden, broken }

/// A request the share host didn't do. [message] is ready for the UI.
class HostedShareException implements Exception {
  const HostedShareException(this.kind, {this.retryAfter});

  final HostedShareError kind;

  /// From `Retry-After` on [HostedShareError.rateLimited].
  final Duration? retryAfter;

  String get message => switch (kind) {
    HostedShareError.network => appL10n.remoteHostedErrNetwork,
    HostedShareError.tooLarge => appL10n.remoteHostedErrTooLarge,
    HostedShareError.rateLimited => appL10n.remoteHostedErrRateLimited,
    HostedShareError.rejected => appL10n.remoteHostedErrCreate,
    HostedShareError.unavailable => appL10n.remoteHostedErrUnavailable,
    HostedShareError.gone => appL10n.remoteHostedErrGone,
    HostedShareError.forbidden => appL10n.remoteHostedErrForbidden,
    HostedShareError.broken => appL10n.remoteHostedErrBroken,
  };

  @override
  String toString() => 'HostedShareException(${kind.name})';
}

class HostedShareClient {
  HostedShareClient({http.Client? client, this.origin = shareHostOrigin, DateTime Function()? clock})
    : _client = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  final http.Client _client;
  final String origin;
  final DateTime Function() _clock;

  /// The host's cap on one blob (20 MB).
  static const maxBlobBytes = 20 * 1024 * 1024;

  /// Files this large are sealed on a background isolate.
  static const _isolateFrom = 256 * 1024;

  static const _timeout = Duration(seconds: 90);

  void close() => _client.close();

  /// Encrypts [file] (a `.dshgo` file's bytes), uploads it and returns the
  /// link. [title] is only kept on the phone.
  Future<HostedLink> upload(Uint8List file, HostedTtl ttl, {String? title}) async {
    final key = newHostedKey();
    final blob = file.length < _isolateFrom ? sealHosted(file, key) : await Isolate.run(() => sealHosted(file, key));
    if (blob.length > maxBlobBytes) throw const HostedShareException(HostedShareError.tooLarge);
    final created = _clock();
    final res = await _send(
      () => _client.post(
        Uri.parse('$origin/api/v1/c?ttl=${ttl.wire}'),
        headers: const {'Content-Type': 'application/octet-stream'},
        body: blob,
      ),
    );
    if (res.statusCode != 201) throw _failure(res);
    final Object? json;
    try {
      json = jsonDecode(res.body);
    } on FormatException {
      throw const HostedShareException(HostedShareError.unavailable);
    }
    if (json is! Map) throw const HostedShareException(HostedShareError.unavailable);
    final id = json['id'];
    final token = json['deleteToken'];
    final expires = json['expiresAt'];
    if (id is! String || !hostedIdPattern.hasMatch(id) || token is! String || token.isEmpty) {
      throw const HostedShareException(HostedShareError.unavailable);
    }
    return HostedLink(
      id: id,
      key: encodeHostedKey(key),
      deleteToken: token,
      title: title == null || title.trim().isEmpty ? appL10n.remoteChat : title.trim(),
      createdAt: created,
      ttl: ttl,
      expiresAt: expires is String ? DateTime.tryParse(expires) : null,
      origin: origin,
    );
  }

  /// Deletes [link] on the host. A link that is already gone (expired,
  /// deleted elsewhere) counts as deleted.
  Future<void> delete(HostedLink link) async {
    final res = await _send(
      () => _client.delete(
        Uri.parse('${link.origin}/api/v1/c/${link.id}'),
        headers: {'Authorization': 'Bearer ${link.deleteToken}'},
      ),
    );
    if (res.statusCode == 204 || res.statusCode == 404) return;
    throw _failure(res);
  }

  /// The file inside a hosted link on this client's host or one of
  /// [hostedOrigins] (for opening one in the app).
  Future<Uint8List> download(String url) async {
    final ref = parseHostedUrl(url);
    if (ref == null || (ref.origin != origin && !hostedOrigins.contains(ref.origin))) {
      throw const HostedShareException(HostedShareError.broken);
    }
    final res = await _send(() => _client.get(Uri.parse('${ref.origin}/api/v1/c/${ref.id}')));
    if (res.statusCode != 200) throw _failure(res);
    final key = decodeHostedKey(ref.key)!;
    final blob = res.bodyBytes;
    try {
      return blob.length < _isolateFrom ? openHosted(blob, key) : await Isolate.run(() => openHosted(blob, key));
    } on HostedFormatException {
      throw const HostedShareException(HostedShareError.broken);
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw const HostedShareException(HostedShareError.network);
    } on SocketException {
      throw const HostedShareException(HostedShareError.network);
    } on HandshakeException {
      throw const HostedShareException(HostedShareError.network);
    } on http.ClientException {
      throw const HostedShareException(HostedShareError.network);
    }
  }

  HostedShareException _failure(http.Response res) {
    switch (res.statusCode) {
      case 413:
        return const HostedShareException(HostedShareError.tooLarge);
      case 429:
        final seconds = int.tryParse(res.headers['retry-after'] ?? '');
        return HostedShareException(
          HostedShareError.rateLimited,
          retryAfter: seconds == null ? null : Duration(seconds: seconds),
        );
      case 404:
        return const HostedShareException(HostedShareError.gone);
      case 401 || 403:
        return const HostedShareException(HostedShareError.forbidden);
      case >= 500:
        return const HostedShareException(HostedShareError.unavailable);
      default:
        return const HostedShareException(HostedShareError.rejected);
    }
  }
}
