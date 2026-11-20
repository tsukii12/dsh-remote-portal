import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'background_session_read_test.dart' as wire;

Object? captured(String endpoint) {
  final rows = jsonDecode(File('test/fixtures/rpc_exchanges.json').readAsStringSync()) as List;
  final row = rows.cast<Map<String, dynamic>>().firstWhere((r) => r['endpoint'] == endpoint);
  return (row['response'] as Map)['result']['value'];
}

Object? fixture(String name) => jsonDecode(File('test/fixtures/$name.json').readAsStringSync());

DshClient connect(HttpServer server, {required bool background, DshTracer? tracer}) {
  final value = DshClient(
    DshConnection(
      Uri.parse('http://127.0.0.1:${server.port}/mount'),
      requestTimeout: const Duration(seconds: 5),
      tracer: tracer,
    ),
    backgroundLists: background,
  );
  addTearDown(value.close);
  return value;
}

void main() {
  for (final background in [false, true]) {
    group(background ? 'list worker' : 'legacy lists', () {
      test('captured model catalog retains defaults, descriptions and effort order', () async {
        final data = captured('session/modelCatalog');
        final server = await wire.host((request, body) async {
          expect(request.uri.path, '/mount/api/session/modelCatalog');
          expect(body['method'], 'session/modelCatalog');
          expect(body['payload'], {'args': <String, Object?>{}});
          await wire.answer(request, wire.envelope(body, data), compressed: true);
        });
        final catalog = await connect(server, background: background).listModels();
        final expected = ModelCatalog.fromJson(data);
        expect(catalog.defaultSelection?.model, expected.defaultSelection?.model);
        expect(catalog.routableProviders, expected.routableProviders);
        expect(catalog.failures, expected.failures);
        expect(
          [for (final m in catalog.models) (m.provider, m.id, m.name, m.description, m.defaultEffort)],
          [for (final m in expected.models) (m.provider, m.id, m.name, m.description, m.defaultEffort)],
        );
        expect(
          [
            for (final m in catalog.models) [for (final e in m.efforts) (e.id, e.name, e.description)],
          ],
          [
            for (final m in expected.models) [for (final e in m.efforts) (e.id, e.name, e.description)],
          ],
        );
      });

      test('captured provider routes and diagnostics retain wire args and typed fields', () async {
        final server = await wire.host((request, body) async {
          expect(body['payload'], {'args': <String, Object?>{}});
          await wire.answer(request, wire.envelope(body, captured(body['method'] as String)));
        });
        final client = connect(server, background: background);
        final routes = await client.listProviders();
        expect(routes, [
          (id: 'deepseek-official', name: 'DeepSeek'),
          (id: 'deepseek-account', name: 'DeepSeek Account'),
        ]);
        final configurable = await client.listConfigurableProviders();
        expect(configurable.map((p) => p.provider), ['amazon-bedrock', 'ant-ling', 'anthropic']);
        expect(configurable.first.settingsPath, ['providers', 'amazon-bedrock']);
        expect(configurable.first.declared, isFalse);
        expect(configurable.first.error, isNull);
      });

      test('captured settings and inventory DTOs survive the isolate boundary', () async {
        final server = await wire.host((request, body) async {
          expect(body['payload'], {'args': <String, Object?>{}});
          final data = body['method'] == 'settings/describe'
              ? fixture('settings_describe')
              : fixture('plugin_inventory');
          await wire.answer(request, wire.envelope(body, data));
        });
        final client = connect(server, background: background);
        final settings = await client.describeSettings();
        expect(settings.hasDocument, isTrue);
        expect(settings.namespaces['subagent']!.value, {'maxDepth': 1, 'maxActiveSubagents': 8});
        expect(settings.namespaces['subagent']!.schema.fields!['maxDepth']!.meta.min, 0);
        expect(settings.namespaces['web-search-deepseek']!.secrets.single.set, isFalse);
        final providers = await client.providerSettings();
        final raw = fixture('settings_describe') as Map;
        final view = (raw['namespaces'] as List).cast<Map<String, dynamic>>().firstWhere(
          (v) => v['ns'] == piAiSettingsNs,
        );
        final expected = ProviderSettings.fromSection(SettingsSection.fromView(piAiSettingsNs, view));
        expect(providers!.profiles.map((p) => p.toJson()), expected.profiles.map((p) => p.toJson()));
        expect(providers.userRoutes, expected.userRoutes);
        expect(providers.baseRoutes, expected.baseRoutes);
        final inventory = await client.pluginInventory();
        final wanted = PluginInventory.fromJson(fixture('plugin_inventory'));
        expect(inventory.managementAvailable, wanted.managementAvailable);
        expect(
          [
            for (final e in inventory.entries)
              (e.entryId, e.moduleName, e.enabled, e.fiberPhase, e.meta?.title?.resolve('zh')),
          ],
          [
            for (final e in wanted.entries)
              (e.entryId, e.moduleName, e.enabled, e.fiberPhase, e.meta?.title?.resolve('zh')),
          ],
        );
        expect(inventory.presets.map((p) => p.id), wanted.presets.map((p) => p.id));
        expect(inventory.presets.map((p) => p.rows.length), wanted.presets.map((p) => p.rows.length));
      });

      test('provider absence remains null and first matching namespace wins', () async {
        var absent = true;
        final server = await wire.host((request, body) async {
          await wire.answer(
            request,
            wire.envelope(body, {
              'writable': false,
              'namespaces': absent
                  ? []
                  : [
                      {
                        'ns': piAiSettingsNs,
                        'revision': 2,
                        'value': {
                          'providers': {
                            'custom-one': {
                              'models': [
                                {'id': 'm', 'extra': null},
                              ],
                            },
                          },
                        },
                      },
                      {'ns': piAiSettingsNs, 'revision': 9, 'value': <String, Object?>{}},
                    ],
            }),
          );
        });
        final client = connect(server, background: background);
        expect(await client.providerSettings(), isNull);
        absent = false;
        final settings = (await client.providerSettings())!;
        expect(settings.revision, 2);
        expect(settings.writable, isFalse);
        expect(settings.profiles.single.models.single.extra, {'extra': null});
      });

      test('plugin bundle and entry metadata preserve localized and optional fields', () async {
        // Same captured shape as plugins_api_test; the identifiers here are
        // deliberately synthetic, and do not assert an installed live plugin.
        final row = {
          'name': 'test-bundle',
          'entryId': 'include:test-plugin',
          'moduleName': 'test-plugin',
          'enabled': true,
          'installed': true,
          'availability': 'profile',
          'version': '1.2.3',
          'meta': {
            'title': {'en': 'Speech', 'zh': '语音'},
            'description': 'kept',
          },
          'rows': [
            {'rowId': 'test-plugin', 'moduleName': 'test-plugin', 'entryId': 'include:test-plugin'},
          ],
          'overrides': <Object?>[],
          'fiberPhase': 'active',
        };
        final server = await wire.host((request, body) async {
          expect(body['payload'], {'args': <String, Object?>{}});
          await wire.answer(request, wire.envelope(body, [row]));
        });
        final client = connect(server, background: background);
        final bundle = (await client.listBundles()).single;
        expect(bundle.name, 'test-bundle');
        expect(bundle.meta!.title!.resolve('zh'), '语音');
        expect(bundle.rows.single.entryId, 'include:test-plugin');
        final plugin = (await client.listPlugins()).single;
        expect(plugin.entryId, 'include:test-plugin');
        expect(plugin.fiberPhase, 'active');
        expect(plugin.meta!.description!.resolve('zh'), 'kept');
      });

      test('credential metadata uses a snapshot of refs and never returns secret values', () async {
        final server = await wire.host((request, body) async {
          expect(body['method'], 'credentials/describe');
          expect(body['payload'], {
            'args': {
              'refs': ['DEEPSEEK_API_KEY', 'DSH_APP_PROBE_DUMMY'],
            },
          });
          await wire.answer(request, wire.envelope(body, captured('credentials/describe')));
        });
        final refs = ['DEEPSEEK_API_KEY', 'DSH_APP_PROBE_DUMMY'];
        final read = connect(server, background: background).describeCredentials(refs);
        refs.clear();
        final result = await read;
        expect(result['DEEPSEEK_API_KEY']!.configured, isTrue);
        expect(result['DEEPSEEK_API_KEY']!.writable, isFalse);
        expect(result['DEEPSEEK_API_KEY']!.source, 'env');
      });

      test('cyclic schema references remain linked after transfer', () async {
        final server = await wire.host((request, body) async {
          await wire.answer(
            request,
            wire.envelope(body, {
              'namespaces': [
                {
                  'ns': 'cycle',
                  'schema': {
                    'uid': 1,
                    'refs': {
                      '1': {
                        'type': 'object',
                        'dict': {'children': 2},
                      },
                      '2': {'type': 'array', 'inner': 3},
                      '3': {'type': 'lazy', 'inner': 1},
                    },
                  },
                },
              ],
            }),
          );
        });
        final node = (await connect(server, background: background).describeSettings()).namespaces['cycle']!.schema;
        expect(identical(node.fields!['children']!.inner!.effective, node), isTrue);
      });
    });
  }

  test('different list kinds share the queue and recover after saturation', () async {
    final release = Completer<void>();
    var entered = 0;
    final server = await wire.host((request, body) async {
      entered++;
      await release.future;
      final endpoint = body['method'] as String;
      final data = endpoint == 'pluginInventory/list' ? fixture('plugin_inventory') : captured(endpoint);
      await wire.answer(request, wire.envelope(body, data));
    });
    final client = connect(server, background: true);
    final first = client.listModels();
    final second = client.listProviders();
    final third = client.pluginInventory();
    final fourth = client.listConfigurableProviders();
    final remaining = List.generate(6, (_) => client.listProviders());
    await expectLater(client.listModels(), throwsA(isA<DshTransportException>()));
    await wire.eventually(() => entered == 2);
    release.complete();
    await Future.wait<Object?>([first, second, third, fourth, ...remaining]);
    expect(await client.listProviders(), hasLength(2));
  });

  test('four initial lists admit the provider metadata fanout before worker exit', () async {
    final releaseModels = Completer<void>();
    final reached = <String>{};
    final server = await wire.host((request, body) async {
      final endpoint = body['method'] as String;
      reached.add(endpoint);
      if (endpoint == 'session/modelCatalog') await releaseModels.future;
      final value = switch (endpoint) {
        'settings/describe' => {
          'namespaces': [
            {
              'ns': piAiSettingsNs,
              'value': {
                'providers': {
                  'custom-one': {'apiKeyEnv': 'DEEPSEEK_API_KEY'},
                },
              },
            },
          ],
        },
        'pluginManager/listBundles' => <Object?>[],
        'session/list' => {'items': <Object?>[]},
        _ => captured(endpoint),
      };
      await wire.answer(request, wire.envelope(body, value));
    });
    final client = connect(server, background: true);
    final model = client.listModels();
    final settings = client.providerSettings();
    final plugins = client.listBundles();
    final sessions = client.listSessions();
    final otherReads = Future.wait<Object?>([model, plugins, sessions]);
    try {
      expect((await settings)!.profiles.single.apiKeyEnv, 'DEEPSEEK_API_KEY');
      final metadata = await Future.wait<Object?>([
        client.describeCredentials(['DEEPSEEK_API_KEY']),
        client.listProviders(),
        client.listConfigurableProviders(),
      ]);
      expect(metadata.every((value) => value != null), isTrue);
      expect(reached, containsAll(['credentials/describe', 'llm/listProviders', 'llm/listConfigurableProviders']));
    } finally {
      releaseModels.complete();
      await otherReads;
    }
  });

  test('all-list opt-in preserves custom carrier dispatch and its refusal', () async {
    final connection = DshConnection(Uri.parse('http://127.0.0.1:1'));
    final carrier = _CustomCarrier(connection);
    final client = DshClient.withCarrier(carrier, backgroundLists: true);
    addTearDown(client.close);
    expect((await client.listModels()).groups, isEmpty);
    expect(await client.providerSettings(), isNull);
    expect(await client.listBundles(), isEmpty);
    await expectLater(client.pluginInventory(), throwsA(isA<DshCarrierRefusedException>()));
    expect(carrier.called, [
      'session/modelCatalog',
      'settings/describe',
      'pluginManager/listBundles',
      'pluginInventory/list',
    ]);
  });

  test('model row overflow fails visibly and preserves subsequent reads', () async {
    var overflow = true;
    final server = await wire.host((request, body) async {
      final data = overflow
          ? {
              'groups': [
                {'id': 'huge', 'models': List.filled(100001, <String, Object?>{})},
              ],
            }
          : captured('session/modelCatalog');
      await wire.answer(request, wire.envelope(body, data));
    });
    final client = connect(server, background: true);
    await expectLater(client.listModels(), throwsA(isA<DshProtocolException>()));
    overflow = false;
    expect((await client.listModels()).models, isNotEmpty);
  });
}

class _CustomCarrier extends DshHttpCarrier {
  _CustomCarrier(super.connection);
  final called = <String>[];
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    called.add(endpoint);
    if (endpoint == 'pluginInventory/list') throw const DshCarrierRefusedException('CUSTOM_REFUSAL', 'custom refusal');
    return const RpcOk(null);
  }
}
