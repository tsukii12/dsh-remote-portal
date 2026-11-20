// GitHub's OAuth device flow, how authors sign in to the Creative Workshop:
// the App needs neither a client secret nor a redirect back into itself.
//
//   requestCode()  POST github.com/login/device/code → a short code the person
//                  types at github.com/login/device
//   pollToken()    POST github.com/login/oauth/access_token, every `interval`,
//                  until they approve, decline, or the code expires
//   user()         GET api.github.com/user → the account's id and login
//
// No scope is requested, so the token can only read the public profile, which
// is all the Worker checks. Both hosts go through the workshop's no-redirect
// transport, one per origin, and no token appears in an error or toString.

import 'dart:convert';

import 'workshop_client.dart' show workshopResponseJson, workshopTransportError;
import 'workshop_http.dart';
import 'workshop_models.dart';

final githubWebOrigin = Uri.parse('https://github.com');
final githubApiOrigin = Uri.parse('https://api.github.com');
final _token = RegExp(r'^[A-Za-z0-9_]{1,255}$');

class GitHubDeviceCode {
  const GitHubDeviceCode({required this.deviceCode, required this.userCode,
    required this.verificationUri, required this.expiresIn, required this.interval});
  /// Whoever holds this and the public client id can collect the token.
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Duration expiresIn, interval;
  @override
  String toString() => 'GitHubDeviceCode(redacted)';
}

enum GitHubPollStatus { pending, slowDown, expired, denied, token }

class GitHubTokenPoll {
  const GitHubTokenPoll._(this.status, [this.token]);
  final GitHubPollStatus status;
  /// Set only for [GitHubPollStatus.token].
  final String? token;
  @override
  String toString() => 'GitHubTokenPoll(${status.name})';
}

class GitHubDeviceFlow {
  GitHubDeviceFlow(WorkshopHttp Function(Uri origin) createHttp)
    : _web = createHttp(githubWebOrigin), _api = createHttp(githubApiOrigin);
  final WorkshopHttp _web, _api;

  void close() {
    _web.close();
    _api.close();
  }

  Future<GitHubDeviceCode> requestCode(String clientId) async {
    final m = await _form('/login/device/code', {'client_id': clientId, 'scope': ''});
    if (const {'incorrect_client_credentials', 'device_flow_disabled'}.contains(m['error'])) {
      workshopInvalid('workshop_account_unconfigured');
    }
    final device = m['device_code'], user = m['user_code'], expires = m['expires_in'];
    final interval = m['interval'] ?? 5;
    final verification = m['verification_uri'] is String ? Uri.tryParse(m['verification_uri'] as String) : null;
    if (!workshopText(device, 255) || user is! String || !RegExp(r'^[A-Z0-9-]{1,32}$').hasMatch(user) ||
        verification == null || verification.scheme != 'https' || verification.host != 'github.com' ||
        verification.hasPort || verification.userInfo.isNotEmpty ||
        expires is! int || expires < 1 || interval is! int || interval < 1) {
      workshopInvalid('workshop_account_unavailable');
    }
    return GitHubDeviceCode(deviceCode: device as String, userCode: user, verificationUri: verification,
      expiresIn: Duration(seconds: expires), interval: Duration(seconds: interval));
  }

  Future<GitHubTokenPoll> pollToken(String clientId, GitHubDeviceCode code) async {
    final m = await _form('/login/oauth/access_token', {'client_id': clientId,
      'device_code': code.deviceCode, 'grant_type': 'urn:ietf:params:oauth:grant-type:device_code'});
    final status = switch (m['error']) {
      'authorization_pending' => GitHubPollStatus.pending,
      'slow_down' => GitHubPollStatus.slowDown,
      'expired_token' => GitHubPollStatus.expired,
      'access_denied' => GitHubPollStatus.denied,
      null => GitHubPollStatus.token,
      _ => workshopInvalid('workshop_account_unavailable'),
    };
    if (status != GitHubPollStatus.token) return GitHubTokenPoll._(status);
    final token = m['access_token'];
    if (token is! String || !_token.hasMatch(token)) workshopInvalid('workshop_account_unavailable');
    return GitHubTokenPoll._(status, token);
  }

  Future<({int id, String login})> user(String token) async {
    try {
      final response = await _api.request('GET', githubApiOrigin.resolve('/user'), headers: {
        'authorization': 'Bearer $token', 'accept': 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
      });
      if (response.status != 200) {
        await response.discard();
        workshopInvalid(response.status == 401 ? 'workshop_account_auth_invalid' : 'workshop_account_unavailable');
      }
      final m = workshopMap(await workshopResponseJson(response, maxBytes: 64 * 1024));
      final id = m['id'], login = m['login'];
      if (id is! int || id < 1 || login is! String || !RegExp(r'^[A-Za-z0-9-]{1,39}$').hasMatch(login)) {
        workshopInvalid('workshop_account_unavailable');
      }
      return (id: id, login: login);
    } on Object catch (error) {
      throw workshopTransportError(error);
    }
  }

  /// OAuth answers its errors in a JSON body, with 200 from GitHub and 400 per
  /// RFC 8628; anything else (a redirect, an outage page) is not an answer.
  Future<Map<String, Object?>> _form(String path, Map<String, String> fields) async {
    try {
      final response = await _web.request('POST', githubWebOrigin.resolve(path), headers: {
        'accept': 'application/json', 'content-type': 'application/x-www-form-urlencoded',
      }, body: utf8.encode(Uri(queryParameters: fields).query));
      if (response.status != 200 && response.status != 400) {
        await response.discard();
        workshopInvalid('workshop_account_unavailable');
      }
      return workshopMap(await workshopResponseJson(response, maxBytes: 64 * 1024));
    } on Object catch (error) {
      throw workshopTransportError(error);
    }
  }
}
