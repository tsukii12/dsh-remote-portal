import 'dart:async';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

PluginOperationResult _result(Map<String, Object?> json) => PluginOperationResult.fromJson(json);

void main() {
  group('failure copy', () {
    test('pnpm-missing differs for the phone and remote hosts', () {
      final result = _result(installResult(application: 'failed', kind: 'pnpm-missing'));
      expect(describeOperationFailure(result, isLocal: true).message, '这台手机缺少 pnpm');
      expect(describeOperationFailure(result, isLocal: false).message, '这台主机缺少 pnpm');
      expect(describeOperationFailure(result, isLocal: false).detail, contains('npm install -g pnpm'));
      expect(describeOperationFailure(result, isLocal: true).kind, PluginFailureKind.pnpmMissing);
    });

    test('an operation the host cancelled midway does not promise that nothing changed', () {
      final failure = describeOperationFailure(_result(installResult(application: 'cancelled')), isLocal: true);
      expect(failure.kind, PluginFailureKind.cancelled);
      expect(failure.title, '已取消安装');
      expect(failure.message, '操作没有完成');
      expect(PluginInstallsController.describeCancelled.message, '没有改动任何东西');
    });

    test('network names the registries, or the spec host', () {
      final viaRegistry = describeOperationFailure(
        _result(
          installResult(
            application: 'failed',
            kind: 'network',
            failedAt: 'registry',
            registries: [null, 'https://registry.npmmirror.com/'],
          ),
        ),
        isLocal: true,
      );
      expect(viaRegistry.kind, PluginFailureKind.network);
      expect(viaRegistry.message, contains('默认安装源、npmmirror 镜像'));
      expect(viaRegistry.retryable, isTrue);
      final viaGit = describeOperationFailure(
        _result(installResult(application: 'failed', kind: 'network', failedAt: 'spec-host')),
        isLocal: true,
      );
      expect(viaGit.message, '连不上插件源码所在的网站');
    });

    test('kinds and codes map to their own copy', () {
      PluginFailure of(Map<String, Object?> json, {DateTime? published, DateTime? now}) =>
          describeOperationFailure(_result(json), isLocal: true, published: published, now: now);

      expect(of(installResult(application: 'failed', kind: 'not-found')).title, '找不到这个插件');
      expect(of(installResult(application: 'failed', kind: 'disk-full')).title, '存储空间不足');
      expect(of(installResult(application: 'failed', kind: 'permission')).kind, PluginFailureKind.permission);
      expect(of(installResult(application: 'failed', kind: 'integrity')).kind, PluginFailureKind.integrity);
      expect(of(installResult(application: 'failed', kind: 'timeout')).title, '下载超时');
      expect(of(installResult(application: 'cancelled')).kind, PluginFailureKind.cancelled);
      expect(
        of(installResult(application: 'failed', error: {'code': 'already-installed'})).kind,
        PluginFailureKind.alreadyInstalled,
      );
      expect(of(installResult(application: 'failed', error: {'code': 'not-bundle'})).title, '这不是 DSH 插件');

      final now = DateTime.utc(2026, 10, 23, 12);
      final fresh = of(
        installResult(application: 'failed', kind: 'no-matching-version'),
        published: now.subtract(const Duration(hours: 3)),
        now: now,
      );
      expect(fresh.kind, PluginFailureKind.tooNew);
      expect(fresh.message, contains('24 小时'));
      final stale = of(
        installResult(application: 'failed', kind: 'no-matching-version'),
        published: now.subtract(const Duration(days: 3)),
        now: now,
      );
      expect(stale.kind, PluginFailureKind.noMatchingVersion);

      final incompatible = of(
        installResult(
          application: 'failed',
          error: {
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
        ),
      );
      expect(incompatible.kind, PluginFailureKind.incompatible);
      expect(incompatible.message, '这个插件要求 DSH >=0.3.0，当前是 0.2.1-rc.2。');

      final blocked = of(installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']));
      expect(blocked.canApproveBuilds, isTrue);
      expect(blocked.pendingBuilds, ['esbuild']);
      expect(blocked.message, contains('esbuild'));

      final unknown = of(
        installResult(
          application: 'failed',
          error: {'code': 'operation-error', 'diagnostic': '\n boom happened\nmore'},
        ),
      );
      expect(unknown.kind, PluginFailureKind.unknown);
      expect(unknown.message, '没能完成，再试一次');
      expect(unknown.detail, contains('more'));
    });

    test('exceptions', () {
      expect(
        describePluginError(const DshRemoteException('METHOD_NOT_ALLOWED', 'x')).kind,
        PluginFailureKind.unsupported,
      );
      expect(describePluginError(const DshRemoteException('gateway/method-not-found', 'x')).title, '主机不支持插件管理');
      expect(describePluginError(const DshTransportException('down')).kind, PluginFailureKind.connection);
    });
  });

  group('market', () {
    late MarketCatalog catalog;
    setUp(() => catalog = MarketCatalog(parseMarketIndex(sampleIndex, Uri.parse(dshfindIndexUrl))));

    List<String> names(MarketFilter filter) => filterMarket(catalog, filter).map((e) => e.name).toList();

    test('web-only heuristic: categories, category titles and package names', () {
      expect(catalog.byName['dsh-pink-skin']!.webOnly, isTrue);
      expect(catalog.byName['novel-writer']!.webOnly, isFalse);
      final index = parseMarketIndex({
        'format': 1,
        'title': 'x',
        'metadata': {
          'categories': {
            'look': {
              'title': {'en': 'Themes & Appearance'},
            },
            'ui': {
              'title': {'en': 'UI Enhancements'},
            },
            'tools': {
              'title': {'en': 'Tools'},
            },
          },
        },
        'plugins': [
          for (final (name, category) in [
            ('a', 'look'),
            ('b', 'ui'),
            ('c', 'tools'),
            ('dsh-client-ui-notes', null),
            ('my-dark-theme', null),
            ('themes-are-not-this', null),
            ('plain', null),
          ])
            {
              'name': name,
              'metadata': {'category': ?category},
              'versions': [
                {
                  'version': '1.0.0',
                  'publishTimestamp': 1,
                  'source': {'type': 'npm'},
                },
              ],
            },
        ],
      }, Uri.parse('https://example.com/i.json'));
      expect(
        {for (final p in index.plugins) p.name: isWebOnlyPlugin(p, index)},
        {
          'a': true,
          'b': true,
          'c': false,
          'dsh-client-ui-notes': true,
          'my-dark-theme': true,
          'themes-are-not-this': true,
          'plain': false,
        },
      );
    });

    test('filters: web-only hidden by default, Chinese substring search, categories', () {
      expect(names(const MarketFilter()), ['novel-writer', 'dsh-approval-gate', 'dsh-memory-lite']);
      expect(hiddenWebOnlyCount(catalog, const MarketFilter()), 1);
      expect(names(const MarketFilter(showWebOnly: true)), hasLength(4));
      expect(names(const MarketFilter(query: '小说')), ['novel-writer']);
      expect(names(const MarketFilter(query: '审批')), ['dsh-approval-gate'], reason: 'keywords are searched');
      expect(names(const MarketFilter(query: 'GATE 小说')), isEmpty, reason: 'every term must match');
      expect(names(const MarketFilter(query: 'approval gatekeeper')), ['dsh-approval-gate']);
      expect(names(const MarketFilter(query: '记忆')), ['dsh-memory-lite']);
      expect(names(const MarketFilter(category: 'tools')), ['dsh-approval-gate']);
      expect(names(const MarketFilter(category: 'skin')), ['dsh-pink-skin'], reason: 'picking the category shows it');
      expect(catalog.categories.map((c) => c.id), ['agent', 'tools', 'skin']);
    });

    test('install status against the installed list', () {
      final bundles = sampleBundles.map(PluginBundle.fromJson).toList();
      final gate = catalog.byName['dsh-approval-gate']!.plugin;
      expect(marketInstallStatus(gate, bundles), MarketInstallStatus.updateAvailable);
      expect(marketInstallStatus(catalog.byName['novel-writer']!.plugin, bundles), MarketInstallStatus.notInstalled);
      final same = [PluginBundle.fromJson(bundleJson('dsh-approval-gate', version: '0.4.0'))];
      expect(marketInstallStatus(gate, same), MarketInstallStatus.installed);
      expect(marketInstallStatus(gate, null), MarketInstallStatus.notInstalled);
    });

    test('bundle groups', () {
      final groups = {for (final b in sampleBundles.map(PluginBundle.fromJson)) b.name: bundleGroup(b)};
      expect(groups, {
        '@deepseek-ai/dsh-base': BundleGroup.hidden,
        'dsh-approval-gate': BundleGroup.installed,
        'broken-thing': BundleGroup.installed,
        '@deepseek-ai/dsh-experimental-session-search': BundleGroup.official,
      });
      final onDemand = PluginBundle.fromJson(
        bundleJson(
          '@deepseek-ai/dsh-subagent-codex',
          official: true,
          installed: false,
          enabled: false,
          removable: false,
          availability: 'missing',
          installTarget: {'spec': '@deepseek-ai/dsh-subagent-codex@0.2.1-rc.2', 'version': '0.2.1-rc.2'},
        ),
      );
      expect(bundleGroup(onDemand), BundleGroup.onDemand);
    });
  });

  group('install queue', () {
    late FakePluginCarrier carrier;
    late DshClient client;
    late ProviderContainer container;

    setUp(() async {
      carrier = FakePluginCarrier();
      client = DshClient.withCarrier(carrier);
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      container = ProviderContainer(overrides: pluginOverrides(fakeHost(client)));
      await client.mux.ready(timeout: const Duration(seconds: 2));
      // Keep the providers alive like the screen does.
      container.listen(installedPluginsProvider, (_, _) {});
      container.listen(pluginInstallsProvider, (_, _) {});
      await container.read(installedPluginsProvider.future);
    });

    tearDown(() async {
      container.dispose();
      await client.close();
    });

    const request = PluginInstallRequest(name: 'novel-writer', spec: 'novel-writer@1.0.2', title: 'novel-writer');

    test('progress events drive the phase; the list is re-read afterwards', () async {
      final finish = Completer<Object?>();
      carrier.handlers['pluginManager/installBundle'] = (args) => finish.future;
      final done = container.read(pluginInstallsProvider.notifier).install(request);
      await pumpEventQueue();
      final job = container.read(pluginInstallsProvider)['novel-writer']!;
      expect(job.phase, PluginInstallPhase.installing);
      final args = carrier.argsOf('pluginManager/installBundle').single;
      expect(args['spec'], 'novel-writer@1.0.2');
      expect(args['options'], {'enabled': true, 'saveExact': true, 'requestId': job.requestId});

      carrier.emit('plugin-manager/install-state', {
        'requestId': job.requestId,
        'phase': 'installing',
        'attempt': {'registry': 'https://registry.npmmirror.com/', 'index': 2, 'total': 2},
      });
      carrier.emit('plugin-manager/install-log', {
        'requestId': job.requestId,
        'jobId': 'j',
        'stream': 'stdout',
        'text': 'Progress: resolved 1\n',
      });
      carrier.emit('plugin-manager/install-log', {
        'requestId': 'someone-else',
        'jobId': 'k',
        'stream': 'stdout',
        'text': 'not mine\n',
      });
      await pumpEventQueue();
      var now = container.read(pluginInstallsProvider)['novel-writer']!;
      expect(now.phaseLabel, '换用npmmirror 镜像下载（第 2/2 个源）');
      expect(now.log, 'Progress: resolved 1\n');
      expect(now.cancellable, isTrue);

      carrier.emit('plugin-manager/install-state', {'requestId': job.requestId, 'phase': 'applying'});
      await pumpEventQueue();
      now = container.read(pluginInstallsProvider)['novel-writer']!;
      expect(now.phase, PluginInstallPhase.applying);
      expect(now.cancellable, isFalse);

      final listCalls = carrier.argsOf('pluginManager/listBundles').length;
      finish.complete(installResult());
      final finished = await done;
      expect(finished.phase, PluginInstallPhase.succeeded);
      expect(finished.needsRestart, isFalse, reason: 'a first install that applied needs no restart');
      expect(finished.phaseLabel, '已安装');
      await pumpEventQueue();
      expect(carrier.argsOf('pluginManager/listBundles').length, greaterThan(listCalls));
    });

    test('installs run one at a time', () async {
      final first = Completer<Object?>();
      carrier.handlers['pluginManager/installBundle'] = (args) =>
          args['spec'] == 'novel-writer@1.0.2' ? first.future : installResult(target: 'b');
      final a = container.read(pluginInstallsProvider.notifier).install(request);
      final b = container
          .read(pluginInstallsProvider.notifier)
          .install(const PluginInstallRequest(name: 'b', spec: 'b@1.0.0'));
      await pumpEventQueue();
      expect(container.read(pluginInstallsProvider)['b']!.phase, PluginInstallPhase.queued);
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1));
      first.complete(installResult());
      expect((await a).phase, PluginInstallPhase.succeeded);
      expect((await b).phase, PluginInstallPhase.succeeded);
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(2));
    });

    test('a queued install can be cancelled before it starts', () async {
      final first = Completer<Object?>();
      carrier.handlers['pluginManager/installBundle'] = (_) => first.future;
      final a = container.read(pluginInstallsProvider.notifier).install(request);
      final b = container
          .read(pluginInstallsProvider.notifier)
          .install(const PluginInstallRequest(name: 'b', spec: 'b@1.0.0'));
      await pumpEventQueue();
      await container.read(pluginInstallsProvider.notifier).cancel('b');
      first.complete(installResult());
      await a;
      expect((await b).phase, PluginInstallPhase.cancelled);
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1));
    });

    test('cancel asks the Host; the install then reports cancelled', () async {
      final finish = Completer<Object?>();
      carrier.handlers['pluginManager/installBundle'] = (_) => finish.future;
      carrier.handlers['pluginManager/cancelInstall'] = (args) {
        finish.complete(installResult(application: 'cancelled'));
        return {'status': 'cancelled'};
      };
      final done = container.read(pluginInstallsProvider.notifier).install(request);
      await pumpEventQueue();
      await container.read(pluginInstallsProvider.notifier).cancel('novel-writer');
      final job = await done;
      expect(job.phase, PluginInstallPhase.cancelled);
      expect(carrier.argsOf('pluginManager/cancelInstall').single['requestId'], job.requestId);
    });

    test('update removes the installed copy first', () async {
      carrier.handlers['pluginManager/removeBundle'] = (_) => {
        'stage': 'remove',
        'target': 'dsh-approval-gate',
        'changed': true,
        'application': 'applied',
      };
      carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: 'dsh-approval-gate');
      final job = await container
          .read(pluginInstallsProvider.notifier)
          .install(
            const PluginInstallRequest(
              name: 'dsh-approval-gate',
              spec: 'dsh-approval-gate@0.4.0',
              replaceInstalled: true,
            ),
          );
      expect(job.phase, PluginInstallPhase.succeeded);
      final order = [for (final (e, _) in carrier.calls) e].where((e) => e != 'pluginManager/listBundles').toList();
      expect(order, ['pluginManager/removeBundle', 'pluginManager/installBundle']);
      // `applied`, but the running engine keeps the old module until it restarts.
      expect(job.needsRestart, isTrue);
      expect(job.phaseLabel, '已安装，重启后生效');
    });

    test('lost response: recovered with waitForInstall', () async {
      carrier.handlers['pluginManager/installBundle'] = (_) => throw const DshTransportException('socket closed');
      carrier.handlers['pluginManager/waitForInstall'] = (_) => installResult();
      final job = await container.read(pluginInstallsProvider.notifier).install(request);
      expect(job.phase, PluginInstallPhase.succeeded);
      expect(carrier.argsOf('pluginManager/waitForInstall').single['requestId'], job.requestId);
    });

    test('lost response and no active install: falls back to the list', () async {
      carrier.handlers['pluginManager/installBundle'] = (_) => throw const DshTransportException('socket closed');
      carrier.handlers['pluginManager/waitForInstall'] = (_) => null;
      final job = await container.read(pluginInstallsProvider.notifier).install(request);
      expect(job.phase, PluginInstallPhase.failed);
      expect(job.failure!.kind, PluginFailureKind.resultUnknown);

      carrier.handlers['pluginManager/listBundles'] = (_) => [...sampleBundles, bundleJson('novel-writer')];
      container.read(pluginInstallsProvider.notifier).dismiss('novel-writer');
      final again = await container.read(pluginInstallsProvider.notifier).install(request);
      expect(again.phase, PluginInstallPhase.succeeded);
    });

    test('approved builds are passed through on retry', () async {
      carrier.handlers['pluginManager/installBundle'] = (args) {
        final options = args['options']! as Map;
        return options.containsKey('approvedBuilds')
            ? installResult()
            : installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']);
      };
      final failed = await container.read(pluginInstallsProvider.notifier).install(request);
      expect(failed.failure!.canApproveBuilds, isTrue);
      final retried = await container
          .read(pluginInstallsProvider.notifier)
          .install(failed.request.withApprovedBuilds(failed.failure!.pendingBuilds));
      expect(retried.phase, PluginInstallPhase.succeeded);
      expect((carrier.argsOf('pluginManager/installBundle').last['options']! as Map)['approvedBuilds'], ['esbuild']);
      expect(retried.needsRestart, isFalse, reason: 'a first install stays a first install');
    });

    test('an update retried with approved builds still asks for a restart', () async {
      carrier.handlers['pluginManager/removeBundle'] = (_) => {
        'stage': 'remove',
        'target': 'dsh-approval-gate',
        'changed': true,
        'application': 'applied',
      };
      carrier.handlers['pluginManager/installBundle'] = (args) {
        final options = args['options']! as Map;
        return options.containsKey('approvedBuilds')
            ? installResult(target: 'dsh-approval-gate')
            : installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']);
      };
      final failed = await container
          .read(pluginInstallsProvider.notifier)
          .install(
            const PluginInstallRequest(
              name: 'dsh-approval-gate',
              spec: 'dsh-approval-gate@0.4.0',
              replaceInstalled: true,
            ),
          );
      expect(failed.failure!.canApproveBuilds, isTrue);
      final retried = await container
          .read(pluginInstallsProvider.notifier)
          .install(failed.request.withApprovedBuilds(failed.failure!.pendingBuilds));
      expect(retried.phase, PluginInstallPhase.succeeded);
      // The first attempt removed the old copy; the retry only installs, and the
      // engine still runs the old module until it restarts.
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
      expect(retried.needsRestart, isTrue);
      expect(retried.phaseLabel, '已安装，重启后生效');
    });

    test('plugin-manager/changed refreshes the installed list', () async {
      final before = carrier.argsOf('pluginManager/listBundles').length;
      carrier.handlers['pluginManager/listBundles'] = (_) => [...sampleBundles, bundleJson('novel-writer')];
      carrier.emit('plugin-manager/changed', {'reason': 'install'});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(carrier.argsOf('pluginManager/listBundles').length, before + 1);
      final names = container.read(installedPluginsProvider).value!.map((b) => b.name);
      expect(names, contains('novel-writer'));
    });

    test('relay hosts cannot install', () async {
      final relayCarrier = FakePluginCarrier(allowInstall: false);
      final relayClient = DshClient.withCarrier(relayCarrier);
      addTearDown(relayClient.close);
      final relay = ProviderContainer(
        overrides: pluginOverrides(fakeHost(relayClient, kind: HostKind.portal, label: '家里的 Mac · 远程')),
      );
      addTearDown(relay.dispose);
      expect(relay.read(pluginHostProvider)!.canInstall, isFalse);
      final job = await relay.read(pluginInstallsProvider.notifier).install(request);
      expect(job.failure!.kind, PluginFailureKind.unsupported);
      expect(relayCarrier.argsOf('pluginManager/installBundle'), isEmpty);
      expect(pluginInstallCommand('novel-writer@1.0.2'), 'dsh plugin --profile web add novel-writer@1.0.2');
    });
  });
}
