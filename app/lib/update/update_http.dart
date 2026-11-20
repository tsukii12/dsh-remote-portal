import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the update code needs from HTTP: one GET with a streamed body. A seam
/// so tests never touch the network.
abstract interface class UpdateHttp {
  /// Resolves once the response headers are in; [timeout] covers connecting
  /// and waiting for them, not the body.
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  });
}

class UpdateHttpResponse {
  UpdateHttpResponse({required this.status, required this.body, this.headers = const {}, this.contentLength});

  final int status;

  /// Lowercase header names.
  final Map<String, String> headers;

  /// Null when the server didn't say.
  final int? contentLength;
  final Stream<List<int>> body;

  /// Reads the body as UTF-8, refusing more than [maxBytes].
  Future<String> text({int maxBytes = 2 * 1024 * 1024, Duration timeout = const Duration(seconds: 20)}) async {
    final bytes = <int>[];
    await for (final chunk in body.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) throw const HttpException('response too large');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Drops the body (frees the connection).
  Future<void> discard() async {
    try {
      final subscription = body.listen(null, cancelOnError: true);
      await subscription.asFuture<void>().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          unawaited(subscription.cancel().catchError((Object _) {}));
        },
      );
    } catch (_) {}
  }
}

/// The updater's User-Agent everywhere but the beta channel.
const updaterAgent = 'dsh-app-updater';

/// The User-Agent of a check on the beta channel, with as much of the
/// installed build as is known: `dsh-app-updater/0.9.9+10301000 (arm64-v8a)`.
/// The share host takes the version and ABI from it (docs/design/share-links.md §15).
String updaterUserAgent({String? version, int? build, String? abi}) {
  final v = version?.trim() ?? '';
  if (!RegExp(r'^[0-9][0-9A-Za-z.-]{0,29}$').hasMatch(v)) return updaterAgent;
  final b = build != null && build > 0 ? '+$build' : '';
  final a = abi != null && RegExp(r'^[a-z0-9_-]{1,16}$').hasMatch(abi) ? ' ($abi)' : '';
  return '$updaterAgent/$v$b$a';
}

/// The real thing, on `dart:io`.
class IoUpdateHttp implements UpdateHttp {
  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // Own the complete redirect chain independently of concurrent GETs.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = updaterAgent;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        timeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('Update response headers timed out', timeout);
        },
      );
      final names = <String, String>{};
      response.headers.forEach((name, values) => names[name.toLowerCase()] = values.join(', '));
      // Stop reuse; the final response body still owns its active connection.
      client.close();
      return UpdateHttpResponse(
        status: response.statusCode,
        headers: names,
        contentLength: response.contentLength >= 0 ? response.contentLength : null,
        body: response,
      );
    } catch (_) {
      // Includes hidden redirect requests and a getUrl still connecting.
      client.close(force: true);
      rethrow;
    }
  }
}
