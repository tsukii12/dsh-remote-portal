// The update check's User-Agent on the beta channel names the installed
// build, `dsh-app-updater/0.9.9+10301000 (arm64-v8a)`, so the share host can
// count versions and ABIs (docs/design/share-links.md §15). Nobody else gets
// more than `dsh-app-updater`. Real sockets here: no binding in this file.

import 'dart:io';

import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/checker.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _token = 'dshc_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG';
const _feed = 'https://go.dshtui.com/beta/update.json';
const _agent = 'dsh-app-updater/0.9.9+10301000 (arm64-v8a)';

/// The share host's reading of it (services/share-worker/src/stats.ts).
final _hostReads = RegExp(r'^dsh-app-updater\/([0-9][0-9A-Za-z.+-]{0,39})(?:\s+\(([a-z0-9_-]{1,16})\))?');

void main() {
  test('the agent: version, build and ABI, as much as is known', () {
    expect(updaterUserAgent(version: '0.9.9', build: 10301000, abi: 'arm64-v8a'), _agent);
    expect(updaterUserAgent(version: '0.9.9', build: 10301000), 'dsh-app-updater/0.9.9+10301000');
    expect(updaterUserAgent(version: '0.9.9', abi: 'x86_64'), 'dsh-app-updater/0.9.9 (x86_64)');
    expect(updaterUserAgent(version: '0.9.9', build: 0), 'dsh-app-updater/0.9.9');
    for (final odd in [null, '', 'v1', '0.9.9 (evil)', '1.0.0\r\nx: y']) {
      expect(updaterUserAgent(version: odd, build: 1, abi: 'arm64-v8a'), updaterAgent, reason: '$odd');
    }
    expect(updaterUserAgent(version: '0.9.9', abi: 'ARM 64'), 'dsh-app-updater/0.9.9');
    final m = _hostReads.firstMatch(_agent)!;
    expect(m[1], '0.9.9+10301000');
    expect(m[2], 'arm64-v8a');
  });

  test('the installed ABI by its Android name', () {
    String? abi(String? dir) => InstalledApp(abi: dir).androidAbi;
    expect(abi('arm64'), 'arm64-v8a');
    expect(abi('arm'), 'armeabi-v7a');
    expect(abi('x86_64'), 'x86_64');
    expect(abi('x86'), 'x86');
    expect(abi('mips'), isNull);
    expect(abi(null), isNull);
  });

  test('only the beta channel hears the version and ABI', () async {
    // The channel is down: the check goes on to GitHub.
    final http = FakeHttp({_feed: (_, _) => textResponse('', status: 503)});
    final checker = UpdateChecker(http: http, sources: buildUpdateSources(channelToken: _token), userAgent: _agent);
    await checker.check();
    expect(http.requests.length, greaterThan(1));
    for (final (url, headers) in http.requests) {
      final channel = url.toString() == _feed;
      expect(headers['user-agent'], channel ? _agent : isNull, reason: '$url');
    }
  });

  test('the app says what the native side reports', () async {
    SharedPreferences.setMockInitialValues({});
    final http = FakeHttp({_feed: (_, _) => textResponse('', status: 503)});
    final dir = Directory.systemTemp.createTempSync('dsh_updater_agent');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(
          FakeInstaller(app: const InstalledApp(versionName: '0.9.9', versionCode: 10301000, abi: 'arm64')),
        ),
        updateSourcesProvider.overrideWithValue(buildUpdateSources(channelToken: _token)),
        updateClockProvider.overrideWithValue(() => DateTime(2026, 10, 30, 9)),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    final controller = c.read(appUpdateProvider.notifier);
    await controller.ready;
    await controller.check();
    final (url, headers) = http.requests.first;
    expect(url.toString(), _feed);
    expect(headers['user-agent'], _agent);
  });

  test('on the wire: the channel\'s agent replaces the default, and nothing else changes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final agents = <String?>[];
    server.listen((request) async {
      agents.add(request.headers.value(HttpHeaders.userAgentHeader));
      request.response.statusCode = 404;
      await request.response.close();
    });
    final http = IoUpdateHttp();
    final url = Uri.parse('http://127.0.0.1:${server.port}/beta/update.json');
    for (final headers in [
      {'user-agent': _agent},
      const <String, String>{},
    ]) {
      final response = await http.get(url, headers: headers);
      await response.discard();
    }
    expect(agents, [_agent, updaterAgent]);
  });
}
