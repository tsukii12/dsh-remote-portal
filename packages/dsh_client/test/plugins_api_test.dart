import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

/// Shapes captured from DSH 0.2.1-rc.2 (`pluginManager/*`, throwaway DSH_HOME).
const _novelWriterBundle = {
  'name': 'novel-writer',
  'official': false,
  'availability': 'profile',
  'version': '1.0.2',
  'description': 'Multi-Core Collaborative Novel Writing',
  'meta': {'title': 'novel-writer', 'description': 'Multi-Core Collaborative Novel Writing'},
  'source': 'novel-writer@1.0.2',
  'enabled': true,
  'installed': true,
  'optional': false,
  'removable': true,
  'rows': [
    {
      'rowId': 'novel-writer',
      'moduleName': 'novel-writer',
      'entryId': 'include:novel-writer',
      'meta': {'title': 'novel-writer'},
    },
  ],
  'overrides': <Object?>[],
};

const _optionalBundle = {
  'name': '@deepseek-ai/dsh-experimental-session-search',
  'official': true,
  'availability': 'installation',
  'version': '0.2.1-rc.2',
  'meta': {
    'title': {'en': 'Session search', 'zh': '会话搜索'},
    'description': {'en': 'Give Agents tools to search earlier sessions.', 'zh': '为智能体提供搜索历史会话的工具。'},
    'icon': 'data:image/svg+xml;base64,PHN2Zy8+',
  },
  'enabled': false,
  'installed': false,
  'optional': true,
  'removable': false,
  'rows': <Object?>[],
  'overrides': <Object?>[],
};

const _onDemandBundle = {
  'name': '@deepseek-ai/dsh-subagent-codex',
  'official': true,
  'availability': 'missing',
  'installTarget': {'spec': '@deepseek-ai/dsh-subagent-codex@0.2.1-rc.2', 'version': '0.2.1-rc.2'},
  'meta': {
    'title': {'en': 'Codex subagent', 'zh': 'Codex 子智能体'},
  },
  'enabled': false,
  'installed': false,
  'optional': false,
  'removable': false,
  'rows': <Object?>[],
  'overrides': <Object?>[],
};

const _installApplied = {
  'stage': 'enable',
  'target': 'novel-writer',
  'enabled': true,
  'changed': true,
  'application': 'applied',
  'registries': [null],
  'packageResult': {
    'exitCode': 0,
    'output': 'Done in 923ms using pnpm v10.34.6\n',
    'truncated': false,
    'logPath': '/h/.dsh/profiles/web/.plugin-manager/logs/operation-Zr6nIi/pnpm.log',
  },
  'bundle': 'novel-writer',
  'version': '1.0.2',
  'warnings': <Object?>[],
};

const _installNotFound = {
  'stage': 'install',
  'target': 'dsh-definitely-not-a-real-pkg-zz9@1.0.0',
  'enabled': true,
  'changed': false,
  'application': 'failed',
  'registries': [null, 'https://registry.npmmirror.com/'],
  'packageResult': {
    'exitCode': 1,
    'output':
        ' ERR_PNPM_FETCH_404  GET https://registry.npmmirror.com/dsh-definitely-not-a-real-pkg-zz9: Not Found - 404',
    'truncated': false,
    'logPath': '/h/pnpm.log',
    'kind': 'not-found',
  },
  'failedAt': 'registry',
  'pendingBuilds': <Object?>[],
  'error': {'code': 'operation-error', 'diagnostic': ' ERR_PNPM_FETCH_404 ...'},
};

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> emit(String event, Map<String, Object?> payload) => {
  'type': 'emit',
  'event': event,
  'args': [payload],
};

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect({bool startMux = false}) =>
      DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux, startMux: startMux);

  group('pluginManager wrappers', () {
    test('listBundles parses installed, optional and on-demand bundles', () async {
      host.handlers['pluginManager/listBundles'] = (args) {
        expect(args, isEmpty);
        return ok([_novelWriterBundle, _optionalBundle, _onDemandBundle]);
      };
      final client = await connect();
      addTearDown(client.close);
      final bundles = await client.listBundles();
      expect(bundles, hasLength(3));

      final novel = bundles[0];
      expect(novel.name, 'novel-writer');
      expect(novel.installed, isTrue);
      expect(novel.removable, isTrue);
      expect(novel.enabled, isTrue);
      expect(novel.version, '1.0.2');
      expect(novel.source, 'novel-writer@1.0.2');
      expect(novel.title(), 'novel-writer');
      expect(novel.rows.single.entryId, 'include:novel-writer');
      expect(novel.isOnDemand, isFalse);

      final search = bundles[1];
      expect(search.official && search.optional, isTrue);
      expect(search.title('zh'), '会话搜索');
      expect(search.title('en'), 'Session search');
      expect(search.title('zh-Hans-CN'), '会话搜索');
      expect(search.summary(), '为智能体提供搜索历史会话的工具。');
      expect(search.meta!.icon, startsWith('data:image/svg+xml'));

      final codex = bundles[2];
      expect(codex.isOnDemand, isTrue);
      expect(codex.installTargetSpec, '@deepseek-ai/dsh-subagent-codex@0.2.1-rc.2');
      expect(codex.title('ja'), 'Codex subagent', reason: 'falls back to English');
    });

    test('installBundle sends spec + options and parses the applied result', () async {
      host.handlers['pluginManager/installBundle'] = (args) {
        expect(args, {
          'spec': 'novel-writer@1.0.2',
          'options': {
            'enabled': true,
            'saveExact': true,
            'requestId': 'req-1',
            'approvedBuilds': ['esbuild'],
            'registry': 'https://registry.npmmirror.com/',
          },
        });
        return ok(_installApplied);
      };
      final client = await connect();
      addTearDown(client.close);
      final result = await client.installBundle(
        'novel-writer@1.0.2',
        requestId: 'req-1',
        enabled: true,
        saveExact: true,
        approvedBuilds: ['esbuild'],
        registry: 'https://registry.npmmirror.com/',
      );
      expect(result.application, PluginApplication.applied);
      expect(result.succeeded, isTrue);
      expect(result.needsRestart, isFalse);
      expect(result.bundle, 'novel-writer');
      expect(result.version, '1.0.2');
      expect(result.registries, [null]);
      expect(result.packageResult!.exitCode, 0);
      expect(result.failureKind, isNull);
    });

    test('installBundle without options omits the options argument', () async {
      host.handlers['pluginManager/installBundle'] = (args) {
        expect(args, {'spec': 'x@1.0.0'});
        return ok(_installNotFound);
      };
      final client = await connect();
      addTearDown(client.close);
      final result = await client.installBundle('x@1.0.0');
      expect(result.application, PluginApplication.failed);
      expect(result.succeeded, isFalse);
      expect(result.failureKind, 'not-found');
      expect(result.error!.code, 'operation-error');
      expect(result.failedAt, 'registry');
      expect(result.registries, [null, 'https://registry.npmmirror.com/']);
    });

    test('restart-required, incompatible-version and pending builds', () async {
      host.handlers['pluginManager/installBundle'] = (_) => ok({
        'stage': 'install',
        'target': 'a@1.0.0',
        'changed': false,
        'application': 'failed',
        'error': {
          'code': 'incompatible-version',
          'incompatible': [
            {
              'name': 'a',
              'version': '1.0.0',
              'runtimeVersion': '0.2.1-rc.2',
              'requirements': {'engines.dsh': '>=0.3.0'},
            },
          ],
        },
        'pendingBuilds': ['esbuild', 'sharp'],
      });
      host.handlers['pluginManager/setBundleEnabled'] = (args) {
        expect(args, {'name': 'a', 'enabled': false});
        return ok({
          'stage': 'enable',
          'target': 'a',
          'changed': true,
          'application': 'restart-required',
          'restartReason': 'no-hmr',
        });
      };
      host.handlers['pluginManager/setPluginEnabled'] = (args) {
        expect(args, {'id': 'include:a', 'enabled': true});
        return ok({'stage': 'enable', 'target': 'include:a', 'changed': false, 'application': 'something-new'});
      };
      final client = await connect();
      addTearDown(client.close);

      final failed = await client.installBundle('a@1.0.0');
      final incompatible = failed.error!.incompatible.single;
      expect(incompatible.requirements, {'engines.dsh': '>=0.3.0'});
      expect(incompatible.runtimeVersion, '0.2.1-rc.2');
      expect(failed.pendingBuilds, ['esbuild', 'sharp']);

      final disabled = await client.setBundleEnabled('a', false);
      expect(disabled.needsRestart, isTrue);
      expect(disabled.restartReason, 'no-hmr');

      final unknown = await client.setPluginEnabled('include:a', true);
      expect(unknown.application, PluginApplication.unknown);
    });

    test('inspect, cancel, wait, remove, registries', () async {
      host.handlers['pluginManager/inspect'] = (args) {
        if (args['spec'] == 'novel-writer') {
          expect(args.containsKey('options'), isFalse);
          return ok({
            'status': 'accepted',
            'kind': 'registry',
            'bundle': true,
            'registry': null,
            'name': 'novel-writer',
            'version': '1.0.2',
          });
        }
        expect(args['options'], {'registry': 'https://r.example/'});
        return ok({
          'status': 'refused',
          'problem': 'not-found',
          'reason': '404',
          'registries': ['https://r.example/'],
        });
      };
      host.handlers['pluginManager/cancelInstall'] = (args) => ok({'status': 'too-late'});
      host.handlers['pluginManager/waitForInstall'] = (args) =>
          ok(args['requestId'] == 'live' ? _installApplied : null);
      host.handlers['pluginManager/removeBundle'] = (args) {
        expect(args, {'name': 'novel-writer'});
        return ok({'stage': 'remove', 'target': 'novel-writer', 'changed': true, 'application': 'applied'});
      };
      host.handlers['pluginManager/registries'] = (_) => ok({
        'registry': null,
        'fallbackRegistries': ['https://registry.npmmirror.com/'],
        'resolved': 'https://registry.npmjs.org/',
      });
      final client = await connect();
      addTearDown(client.close);

      final accepted = await client.inspectPlugin('novel-writer');
      expect(accepted, isA<PluginInspectionAccepted>().having((i) => i.bundle, 'bundle', isTrue));
      final refused = await client.inspectPlugin('nope', registry: 'https://r.example/');
      expect(refused, isA<PluginInspectionRefused>().having((i) => i.problem, 'problem', 'not-found'));

      expect(await client.cancelInstall('r'), PluginCancelStatus.tooLate);
      expect(await client.waitForInstall('gone'), isNull);
      expect((await client.waitForInstall('live'))!.bundle, 'novel-writer');
      expect((await client.removeBundle('novel-writer')).succeeded, isTrue);
      final registries = await client.pluginRegistries();
      expect(registries.registry, isNull);
      expect(registries.fallbackRegistries, ['https://registry.npmmirror.com/']);
    });

    test('Host refusals surface as DshRemoteException', () async {
      host.handlers['pluginManager/removeBundle'] = (_) => {
        'ok': false,
        'error': {'code': 'gateway/arguments-invalid', 'message': 'bad', 'details': <String, Object?>{}},
      };
      final client = await connect();
      addTearDown(client.close);
      await expectLater(
        client.removeBundle('x'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'gateway/arguments-invalid')),
      );
      expect(client.canInstallPlugins, isTrue);
    });
  });

  group('plugin-manager events', () {
    test('install-state, install-log and changed reach pluginManagerEvents', () async {
      final client = await connect(startMux: true);
      addTearDown(client.close);
      final events = <PluginManagerEvent>[];
      final sub = client.pluginManagerEvents.listen(events.add);
      addTearDown(sub.cancel);

      final socket = host.sockets.single;
      socket.event(
        emit('plugin-manager/install-state', {
          'requestId': 'req-1',
          'phase': 'installing',
          'attempt': {'registry': 'https://registry.npmmirror.com/', 'index': 2, 'total': 2},
        }),
      );
      socket.event(
        emit('plugin-manager/install-log', {
          'requestId': 'req-1',
          'jobId': 'job',
          'argv': ['pnpm', 'add', 'novel-writer@1.0.2'],
          'cwd': '/h',
          'stream': 'stdout',
          'text': 'Progress: resolved 1\n',
        }),
      );
      socket.event(
        emit('plugin-manager/install-log', {
          'requestId': 'req-1',
          'jobId': 'job',
          'argv': ['pnpm', 'add', 'novel-writer@1.0.2'],
          'stream': 'stdout',
          'text': '',
          'exitCode': 0,
        }),
      );
      socket.event(emit('plugin-manager/changed', {'reason': 'install'}));
      socket.event(emit('api-session/status', {'x': 1}));

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(events, hasLength(4));
      final state = events[0] as PluginInstallStateEvent;
      expect(state.requestId, 'req-1');
      expect(state.phase, 'installing');
      expect(state.registry, 'https://registry.npmmirror.com/');
      expect((state.attemptIndex, state.attemptTotal), (2, 2));
      final log = events[1] as PluginInstallLogEvent;
      expect(log.text, 'Progress: resolved 1\n');
      expect(log.finished, isFalse);
      expect((events[2] as PluginInstallLogEvent).finished, isTrue);
      expect((events[2] as PluginInstallLogEvent).exitCode, 0);
      expect((events[3] as PluginManagerChangedEvent).reason, 'install');
    });

    test('fromHostEvent ignores other events', () {
      expect(PluginManagerEvent.fromHostEvent(const SessionStatusEvent('s', true)), isNull);
      expect(
        PluginManagerEvent.fromHostEvent(const UnknownHostEvent('llm/adapters-updated', {'args': <Object?>[]})),
        isNull,
      );
      expect(
        PluginManagerEvent.fromHostEvent(const UnknownHostEvent('plugin-manager/new-thing', {'args': <Object?>[]})),
        isA<PluginManagerOtherEvent>(),
      );
    });
  });

  group('LocalizedText', () {
    test('resolution order', () {
      final text = LocalizedText.fromJson({'en': 'Hello', 'zh-cn': '你好', 'ja': ''})!;
      expect(text.resolve('zh'), '你好');
      expect(text.resolve('zh-CN'), '你好');
      expect(text.resolve('ko'), 'Hello');
      expect(text.values.containsKey('ja'), isFalse, reason: 'blank members dropped');
      expect(LocalizedText.fromJson('  '), isNull);
      expect(LocalizedText.fromJson(3), isNull);
      expect(LocalizedText.fromJson('plain')!.toJson(), 'plain');
    });

    // What schemastery 3.18.5 `.description('…').i18n({…})` serializes:
    // mergeDesc keeps the plain description under '' beside each locale.
    test('plain text written in the UI language beats English', () {
      final retries = LocalizedText.fromJson({'': '最大重试次数', 'en': 'Maximum retries'})!;
      expect(retries.resolve('zh'), '最大重试次数');
      expect(retries.resolve('en'), 'Maximum retries');
      final endpoint = LocalizedText.fromJson({'': 'Upstream endpoint', 'zh-CN': '上游地址', 'en': 'Upstream'})!;
      expect(endpoint.resolve('zh'), '上游地址');
      expect(endpoint.resolve('en'), 'Upstream');
      final english = LocalizedText.fromJson({'': 'Retries', 'ja': 'リトライ'})!;
      expect(english.resolve('zh'), 'Retries', reason: 'no Chinese: plain text before an unrelated language');
    });

    test('underscore ids and English variants', () {
      final region = LocalizedText.fromJson({'en_US': 'Region', 'zh_CN': '区域'})!;
      expect(region.values.keys, ['en-us', 'zh-cn']);
      expect(region.resolve('zh'), '区域');
      expect(region.resolve('zh_CN'), '区域');
      expect(region.resolve('en'), 'Region');
      expect(LocalizedText.fromJson({'ja': 'リトライ', 'en-US': 'Retries'})!.resolve('zh'), 'Retries');
      // Strict market text keeps its keys as written; resolving still matches.
      expect(const LocalizedText({'en': 'Weather', 'zh-CN': '天气'}).resolve('zh'), '天气');
    });
  });
}
