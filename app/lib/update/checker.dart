import 'dart:convert';
import 'dart:io';

import 'release.dart';
import 'update_config.dart';
import 'update_http.dart';
import 'version.dart';

/// Why no endpoint could say what the latest release is. All of them read
/// "暂时检查不了更新" to the person; the kind is for logs and tests.
enum CheckFailure {
  /// No connection, DNS, timeout, TLS.
  network,

  /// GitHub API rate limit (403/429 with the limit spent).
  rateLimited,

  /// 404 everywhere: no release yet, or the repository is private.
  noRelease,

  /// Answered, but not with a usable release.
  badResponse,
}

sealed class CheckResult {
  const CheckResult();
}

final class CheckFound extends CheckResult {
  const CheckFound(this.release, this.endpoint);

  final ReleaseInfo release;

  /// The endpoint that answered (remembered as the next check's first try).
  final UpdateEndpoint endpoint;
}

final class CheckFailed extends CheckResult {
  const CheckFailed(this.failure, {this.attempts = const []});

  final CheckFailure failure;

  /// Endpoint id → what went wrong, in order.
  final List<(String, CheckFailure)> attempts;
}

/// Asks the metadata endpoints in order until one answers with a release.
class UpdateChecker {
  const UpdateChecker({required this.http, required this.sources, this.userAgent});

  final UpdateHttp http;
  final UpdateSources sources;

  /// Sent to the beta channel only ([updaterUserAgent]); the other sources
  /// get the plain [updaterAgent].
  final String? userAgent;

  static const _timeout = Duration(seconds: 12);

  Future<CheckResult> check({
    String? preferred,
    void Function(UpdateEndpoint endpoint)? onAttempt,
    /// What this build is. A source that answers with something no newer than
    /// this is not the end of the search: another source may still know a
    /// release (a stale channel must not hide the GitHub release). Null keeps
    /// the old behaviour of taking the first answer.
    AppVersion? installed,
  }) async {
    final attempts = <(String, CheckFailure)>[];
    CheckFound? stale;
    for (final endpoint in sources.metadataEndpoints(preferred: preferred)) {
      onAttempt?.call(endpoint);
      final outcome = await _try(endpoint);
      switch (outcome) {
        case ReleaseInfo release:
          final found = CheckFound(release, endpoint);
          if (installed == null || release.version.isNewerThan(installed)) return found;
          // Answering with an older release is not proof that nothing newer
          // exists: keep the newest answer and ask the next source.
          if (stale == null || release.version.isNewerThan(stale.release.version)) stale = found;
        case CheckFailure failure:
          attempts.add((endpoint.id, failure));
      }
    }
    return stale ?? CheckFailed(_summarize(attempts.map((a) => a.$2)), attempts: attempts);
  }

  /// Rate limiting wins (it tells the person "later" for sure); 404 only
  /// when every endpoint said so; otherwise network unless something answered
  /// with garbage.
  static CheckFailure _summarize(Iterable<CheckFailure> failures) {
    final all = failures.toSet();
    if (all.contains(CheckFailure.rateLimited)) return CheckFailure.rateLimited;
    if (all.length == 1 && all.single == CheckFailure.noRelease) return CheckFailure.noRelease;
    if (all.contains(CheckFailure.badResponse)) return CheckFailure.badResponse;
    if (all.isEmpty) return CheckFailure.noRelease;
    return CheckFailure.network;
  }

  Future<Object> _try(UpdateEndpoint endpoint) async {
    final UpdateHttpResponse response;
    try {
      response = await http.get(
        endpoint.url,
        headers: {
          ...endpoint.kind == EndpointKind.githubApi
              ? const {'accept': 'application/vnd.github+json', 'x-github-api-version': '2022-11-28'}
              : const {'accept': 'application/json'},
          ...endpoint.headers,
          if (userAgent case final agent? when endpoint.id == UpdateChannel.endpointId) 'user-agent': agent,
        },
        timeout: _timeout,
      );
    } on Object {
      // SocketException, TimeoutException, HandshakeException, HttpException…
      return CheckFailure.network;
    }
    if (response.status != HttpStatus.ok) {
      await response.discard();
      return switch (response.status) {
        403 ||
        429 when response.headers['x-ratelimit-remaining'] == '0' || response.status == 429 => CheckFailure.rateLimited,
        404 => CheckFailure.noRelease,
        >= 500 => CheckFailure.network,
        _ => CheckFailure.badResponse,
      };
    }
    final String body;
    try {
      body = await response.text(timeout: _timeout);
    } on Object {
      return CheckFailure.network;
    }
    try {
      final json = jsonDecode(body);
      return switch (endpoint.kind) {
        EndpointKind.githubApi => parseGithubRelease(json),
        EndpointKind.manifest => parseUpdateManifest(json, base: endpoint.url),
      };
    } on Object {
      // FormatException, or a TypeError from a field of the wrong type. Some
      // mirrors answer 200 with an HTML error page.
      return CheckFailure.badResponse;
    }
  }
}
