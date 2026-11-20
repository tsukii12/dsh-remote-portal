// The network a share code touches, all optional and read-only except an
// explicit Gist upload: npm version metadata (integrity, publisher, size) and
// GitHub Gists for profiles too large to inline. A seam so tests answer without
// a network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';

/// What the registry says about one npm version.
class NpmFacts {
  const NpmFacts({this.integrity, this.publisher, this.unpackedSize, this.description});

  /// `dist.integrity` (`sha512-…`).
  final String? integrity;

  /// `_npmUser.name`: who published this version.
  final String? publisher;

  /// `dist.unpackedSize` in bytes.
  final int? unpackedSize;
  final String? description;
}

/// The Gist could not be created or read.
class GistException implements Exception {
  const GistException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;

  @override
  String toString() => message;
}

abstract class ShareNet {
  /// Null when no registry answered (offline, blocked, unknown version).
  Future<NpmFacts?> npmFacts(String name, String version);

  /// Uploads [content] as a secret Gist with one file; returns its id.
  Future<String> createGist({required String token, required String fileName, required String content});

  /// The text of the Gist's `.dshgo` file.
  Future<String> fetchGist(String id);
}

class HttpShareNet implements ShareNet {
  HttpShareNet({HttpClient Function()? client}) : _client = client ?? HttpClient.new;

  final HttpClient Function() _client;

  /// The public registry first, then the npmmirror copy (same tarballs, same
  /// integrity), which answers where the first one is slow.
  static const registries = ['https://registry.npmjs.org', 'https://registry.npmmirror.com'];

  @override
  Future<NpmFacts?> npmFacts(String name, String version) async {
    final path = '${Uri.encodeComponent(name).replaceAll('%40', '@')}/${Uri.encodeComponent(version)}';
    for (final registry in registries) {
      try {
        final json = await _getJson(Uri.parse('$registry/$path'), timeout: const Duration(seconds: 6));
        if (json is! Map) continue;
        final dist = json['dist'];
        final user = json['_npmUser'];
        return NpmFacts(
          integrity: dist is Map && dist['integrity'] is String ? dist['integrity'] as String : null,
          publisher: user is Map && user['name'] is String ? user['name'] as String : null,
          unpackedSize: dist is Map && dist['unpackedSize'] is int ? dist['unpackedSize'] as int : null,
          description: json['description'] is String ? json['description'] as String : null,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @override
  Future<String> createGist({required String token, required String fileName, required String content}) async {
    final http = _client()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await http.postUrl(Uri.parse('https://api.github.com/gists'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${token.trim()}')
        ..set('X-GitHub-Api-Version', '2022-11-28')
        ..contentType = ContentType.json;
      request.add(
        utf8.encode(
          jsonEncode({
            'description': appL10n.pluginsProfileTitle,
            'public': false,
            'files': {
              fileName: {'content': content},
            },
          }),
        ),
      );
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await _read(response, 1024 * 1024);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw GistException(appL10n.pluginsGistTokenInvalid, unauthorized: true);
      }
      if (response.statusCode != 201) throw GistException(appL10n.pluginsGistCreateHttpFailed(response.statusCode));
      final json = jsonDecode(text);
      final id = json is Map ? json['id'] : null;
      if (id is! String) throw GistException(appL10n.pluginsGistCreateFailed);
      return id;
    } on SocketException {
      throw GistException(appL10n.pluginsGitHubUnreachable);
    } on TimeoutException {
      throw GistException(appL10n.pluginsGitHubTimeout);
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<String> fetchGist(String id) async {
    try {
      final text = await _getText(Uri.parse('https://api.github.com/gists/$id'), timeout: const Duration(seconds: 15));
      final json = await compute(jsonDecode, text);
      final files = json is Map ? json['files'] : null;
      if (files is! Map) throw GistException(appL10n.pluginsGistNotFound);
      for (final file in files.values) {
        if (file is! Map) continue;
        final name = file['filename'];
        if (name is! String || !name.endsWith('.dshgo')) continue;
        if (file['truncated'] != true && file['content'] is String) return file['content'] as String;
        final raw = file['raw_url'];
        if (raw is String && raw.startsWith('https://gist.githubusercontent.com/')) {
          return await _getText(Uri.parse(raw), timeout: const Duration(seconds: 20));
        }
      }
      throw GistException(appL10n.pluginsGistNoProfile);
    } on GistException {
      rethrow;
    } on SocketException {
      throw GistException(appL10n.pluginsGitHubUnreachable);
    } on TimeoutException {
      throw GistException(appL10n.pluginsGitHubTimeout);
    } on HttpException catch (e) {
      throw GistException(e.message.contains('404') ? appL10n.pluginsGistNotFound : appL10n.pluginsGistReadFailed);
    }
  }

  Future<Object?> _getJson(Uri url, {required Duration timeout}) async =>
      jsonDecode(await _getText(url, timeout: timeout));

  Future<String> _getText(Uri url, {required Duration timeout}) async {
    final http = _client()
      ..connectionTimeout = timeout
      ..userAgent = 'dsh-app';
    try {
      final request = await http.getUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      return await _read(response, 2 * 1024 * 1024).timeout(timeout);
    } finally {
      http.close(force: true);
    }
  }

  static Future<String> _read(HttpClientResponse response, int limit) async {
    final buffer = StringBuffer();
    await for (final chunk in response.transform(utf8.decoder)) {
      if (buffer.length + chunk.length > limit) throw const HttpException('response too large');
      buffer.write(chunk);
    }
    return buffer.toString();
  }
}

final shareNetProvider = Provider<ShareNet>((ref) => HttpShareNet());
