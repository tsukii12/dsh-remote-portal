import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/github_device_flow.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> deviceCodeJson({String uri = 'https://github.com/login/device'}) => {
  'device_code': 'device_secret_0123', 'user_code': 'WDJB-MJHT', 'verification_uri': uri,
  'expires_in': 900, 'interval': 5,
};

GitHubDeviceCode _code() => GitHubDeviceCode(deviceCode: 'device_secret_0123', userCode: 'WDJB-MJHT',
  verificationUri: Uri.parse('https://github.com/login/device'), expiresIn: const Duration(minutes: 15),
  interval: const Duration(seconds: 5));

void main() {
  late FakeWorkshopHttp http;
  late GitHubDeviceFlow flow;
  final origins = <Uri>[];

  setUp(() {
    origins.clear();
    http = FakeWorkshopHttp((method, url, headers, body) => throw StateError('unexpected $url'));
    flow = GitHubDeviceFlow((origin) {
      origins.add(origin);
      return http;
    });
  });

  test('asks github.com for a code with no scope and reads it', () async {
    http.route = (method, url, headers, body) => workshopJsonResponse(deviceCodeJson());
    final code = await flow.requestCode('Iv1.test');
    expect(origins, [Uri.parse('https://github.com'), Uri.parse('https://api.github.com')]);
    final request = http.requests.single;
    expect((request.method, request.url.toString()), ('POST', 'https://github.com/login/device/code'));
    expect(request.headers['accept'], 'application/json');
    expect(Uri.splitQueryString(utf8.decode(request.body!)), {'client_id': 'Iv1.test', 'scope': ''});
    expect((code.userCode, code.verificationUri.toString()), ('WDJB-MJHT', 'https://github.com/login/device'));
    expect((code.expiresIn, code.interval), (const Duration(minutes: 15), const Duration(seconds: 5)));
    expect(code.toString(), isNot(contains('device_secret')));
  });

  test('a verification page that is not https on github.com is refused', () async {
    for (final uri in ['http://github.com/login/device', 'https://github.com.example/login/device',
      'https://evil.example/login/device', 'https://user@github.com/login/device']) {
      http.route = (method, url, headers, body) => workshopJsonResponse(deviceCodeJson(uri: uri));
      await expectLater(flow.requestCode('Iv1.test'), workshopError('workshop_account_unavailable'), reason: uri);
    }
  });

  test('a disabled device flow or unknown client reads as unconfigured', () async {
    http.route = (method, url, headers, body) => workshopJsonResponse({'error': 'device_flow_disabled'}, status: 400);
    await expectLater(flow.requestCode('Iv1.test'), workshopError('workshop_account_unconfigured'));
  });

  test('a redirect is not an answer', () async {
    http.route = (method, url, headers, body) => UpdateHttpResponse(status: 302,
      headers: const {'location': 'https://elsewhere.example/'}, body: const Stream.empty());
    await expectLater(flow.requestCode('Iv1.test'), workshopError('workshop_account_unavailable'));
  });

  test('polling reads pending, slow_down, then the token, sending the device grant', () async {
    final answers = [
      {'error': 'authorization_pending'},
      {'error': 'slow_down', 'interval': 10},
      {'access_token': 'gho_test_token_1', 'token_type': 'bearer', 'scope': ''},
    ];
    http.route = (method, url, headers, body) => workshopJsonResponse(answers.removeAt(0));
    final code = _code();
    final polls = [for (var i = 0; i < 3; i++) await flow.pollToken('Iv1.test', code)];
    expect(polls.map((poll) => poll.status), [GitHubPollStatus.pending, GitHubPollStatus.slowDown, GitHubPollStatus.token]);
    expect(polls.last.token, 'gho_test_token_1');
    expect(polls.last.toString(), isNot(contains('gho_')));
    final request = http.requests.first;
    expect(request.url.toString(), 'https://github.com/login/oauth/access_token');
    expect(Uri.splitQueryString(utf8.decode(request.body!)), {'client_id': 'Iv1.test',
      'device_code': 'device_secret_0123', 'grant_type': 'urn:ietf:params:oauth:grant-type:device_code'});
  });

  test('expired and denied codes end the poll; other errors are failures', () async {
    final code = _code();
    for (final (error, status) in [('expired_token', GitHubPollStatus.expired), ('access_denied', GitHubPollStatus.denied)]) {
      http.route = (method, url, headers, body) => workshopJsonResponse({'error': error}, status: 400);
      expect((await flow.pollToken('Iv1.test', code)).status, status);
    }
    http.route = (method, url, headers, body) => workshopJsonResponse({'error': 'incorrect_device_code'});
    await expectLater(flow.pollToken('Iv1.test', code), workshopError('workshop_account_unavailable'));
    http.route = (method, url, headers, body) => workshopJsonResponse({'access_token': 'not a token'});
    await expectLater(flow.pollToken('Iv1.test', code), workshopError('workshop_account_unavailable'));
  });

  test('reads the profile from api.github.com with the token', () async {
    http.route = (method, url, headers, body) => workshopJsonResponse({'id': 583231, 'login': 'octo-cat', 'name': 'Octo'});
    expect(await flow.user('gho_test_token_1'), (id: 583231, login: 'octo-cat'));
    final request = http.requests.single;
    expect((request.method, request.url.toString()), ('GET', 'https://api.github.com/user'));
    expect(request.headers, {'authorization': 'Bearer gho_test_token_1', 'accept': 'application/vnd.github+json',
      'x-github-api-version': '2022-11-28'});
    http.route = (method, url, headers, body) => workshopJsonResponse({'message': 'Bad credentials'}, status: 401);
    await expectLater(flow.user('gho_test_token_1'), workshopError('workshop_account_auth_invalid'));
    http.route = (method, url, headers, body) => throw const SocketException('offline');
    await expectLater(flow.user('gho_test_token_1'), workshopError('workshop_network'));
  });
}
