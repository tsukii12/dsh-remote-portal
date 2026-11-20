import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

/// `settings/describe` of a throwaway DSH 0.2.1-rc.2 (`dsh web`, fresh HOME,
/// the thinking-translation and plugin-market bundles switched on).
Map<String, Object?> describeFixture() =>
    jsonDecode(File('test/fixtures/settings_describe.json').readAsStringSync()) as Map<String, Object?>;

/// `pluginInventory/list` of the same Host, trimmed to a few entries and two
/// presets.
Map<String, Object?> inventoryFixture() =>
    jsonDecode(File('test/fixtures/plugin_inventory.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  group('schemastery', () {
    late SettingsDescription described;
    setUp(() => described = SettingsDescription.fromJson(describeFixture()));

    test('rehydrates every namespace with its fields', () {
      expect(described.writable, isTrue);
      expect(described.hasDocument, isTrue);
      expect(described.namespaces.keys, containsAll(['subagent', 'agent-loop', 'bash-sandbox', 'web', 'ui-chat']));
      final subagent = described.namespaces['subagent']!;
      expect(subagent.autoGenerate, isTrue);
      expect(subagent.value, {'maxDepth': 1, 'maxActiveSubagents': 8});
      expect(subagent.user, isEmpty);
      final depth = subagent.schema.fields!['maxDepth']!;
      expect(depth.type, 'number');
      expect(depth.meta.min, 0);
      expect(depth.meta.step, 1);
      expect(depth.meta.defaultValue, 1);
      expect(subagent.schema.fields!.keys, ['maxDepth', 'maxActiveSubagents']);
    });

    test('roles, enums, nullable enums and patterns', () {
      final search = described.namespaces['web-search-deepseek']!;
      expect(search.schema.fields!['apiKey']!.isSecret, isTrue);
      expect(search.schema.fields!['apiKeyEnv']!.isCredentialRef, isTrue);
      expect(search.secrets.single.path, ['apiKey']);
      expect(search.secrets.single.set, isFalse);
      expect(search.value.containsKey('apiKey'), isFalse);

      final chat = described.namespaces['ui-chat']!;
      expect(chat.autoGenerate, isFalse);
      expect(chat.schema.fields!['linkOpening']!.enumValues, ['sidebar', 'new-tab']);
      expect(chat.schema.fields!['transcriptView']!.meta.loose, isTrue);

      final account = described.namespaces['ui-settings-account']!.schema.fields!;
      expect(account['purpose']!.nullable, isTrue);
      expect(account['purpose']!.enumValues, ['office', 'development', 'both']);
      expect(account['version']!.enumValues, [1]);

      final cot = described.namespaces['cot-translation']!.schema.fields!;
      expect(cot['provider']!.enumValues, hasLength(4));
      expect(cot['targetLanguage']!.meta.pattern, startsWith('^(?:auto|'));

      final market = described.namespaces['plugin-market']!.schema.fields!['indexes']!;
      expect(market.type, 'array');
      expect(market.inner!.type, 'string');
      expect(market.inner!.meta.pattern, isNotNull);

      final retry = described.namespaces['llm-deepseek']!.schema.fields!['retryPolicy']!;
      expect(retry.enumValues, isNull, reason: 'a union of objects is not an enum');
      expect(retry.members.map((m) => m.type), ['object', 'object']);
    });

    test('a recursive (lazy) schema links without looping', () {
      final node = SchemaNode.fromJson({
        'uid': 1,
        'refs': {
          '1': {
            'type': 'object',
            'meta': {'default': <String, Object?>{}},
            'dict': {'name': 2, 'children': 3},
          },
          '2': {'type': 'string', 'meta': <String, Object?>{}},
          '3': {'type': 'array', 'meta': <String, Object?>{}, 'inner': 4},
          '4': {'type': 'lazy', 'meta': <String, Object?>{}, 'inner': 1},
        },
      });
      final children = node.fields!['children']!;
      expect(identical(children.inner!.effective, node), isTrue);
      expect(children.inner!.effective.fields!.keys, ['name', 'children']);
    });

    test('inline nodes and intersections', () {
      final node = SchemaNode.fromJson({
        'type': 'intersect',
        'list': [
          {
            'type': 'object',
            'dict': {
              'a': {'type': 'string'},
            },
          },
          {
            'type': 'object',
            'dict': {
              'b': {
                'type': 'boolean',
                'meta': {'default': true},
              },
            },
          },
        ],
      });
      expect(node.fields!.keys, ['a', 'b']);
      expect(node.fields!['b']!.meta.defaultValue, isTrue);
      expect(SchemaNode.fromJson('nope').type, 'unknown');
    });

    test('a complete schema keeps the live marker of a volatile node', () {
      final node = SchemaNode.fromJson({
        'type': 'object',
        'dict': {
          'language': {
            'type': 'string',
            'meta': {'volatile': true, 'default': 'auto'},
          },
          'threads': {
            'type': 'number',
            'meta': {'default': 2},
          },
        },
      });
      expect(node.fields!['language']!.meta.volatile, isTrue);
      expect(node.fields!['threads']!.meta.volatile, isFalse);
      // settings/describe strips it: what it serves is live already.
      final described = SettingsDescription.fromJson(describeFixture());
      expect(described.namespaces['subagent']!.schema.fields!['maxDepth']!.meta.volatile, isFalse);
    });
  });

  group('values', () {
    test('lookup, set and unset by path', () {
      final root = <String, Object?>{
        'a': {'b': 1},
        'list': [
          {'x': 1},
        ],
      };
      expect(lookupPath(root, ['a', 'b']), (true, 1));
      expect(lookupPath(root, ['a', 'c']), (false, null));
      expect(lookupPath(root, ['list', '0', 'x']), (true, 1));
      expect(withPath(root, ['a', 'c'], 2), {
        'a': {'b': 1, 'c': 2},
        'list': [
          {'x': 1},
        ],
      });
      expect(withPath(null, ['n', 'm'], true), {
        'n': {'m': true},
      });
      expect(withoutPath(root, ['a', 'b'])['a'], isEmpty);
      expect(root['a'], {'b': 1}, reason: 'never mutated');
      expect(
        jsonEquals(
          {
            'a': 1,
            'b': [1, 2],
          },
          {
            'b': [1, 2.0],
            'a': 1,
          },
        ),
        isTrue,
      );
      expect(jsonEquals([1], [1, 2]), isFalse);
    });
  });

  group('calls', () {
    late FakeDsh host;
    setUp(() async => host = await FakeDsh.start());
    tearDown(() async => host.close());

    Future<DshClient> connect() async {
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
      addTearDown(client.close);
      return client;
    }

    test('describe passes the writable flag down; mutate sends ns, ops and revision', () async {
      final fixture = describeFixture()..['writable'] = false;
      host.handlers['settings/describe'] = (_) => ok(fixture);
      final subagent = (fixture['namespaces']! as List).cast<Map<String, Object?>>().firstWhere(
        (n) => n['ns'] == 'subagent',
      );
      host.handlers['settings/mutate'] = (args) => ok({
        ...subagent,
        'value': {'maxDepth': 3, 'maxActiveSubagents': 8},
        'user': {'maxDepth': 3},
        'revision': 1,
      });
      final client = await connect();
      final described = await client.describeSettings();
      expect(described.namespaces['subagent']!.writable, isFalse);

      final view = await client.mutateSettingsView('subagent', [
        const SettingsOp.set(['maxDepth'], 3),
        const SettingsOp.unset(['maxActiveSubagents']),
      ], expectedRevision: 0);
      expect(view.value['maxDepth'], 3);
      expect(view.user, {'maxDepth': 3});
      expect(view.revision, 1);
      expect(view.schema.fields!.keys, ['maxDepth', 'maxActiveSubagents']);
      final args = (host.rpcCalls.last['payload']! as Map)['args'];
      expect(args, {
        'ns': 'subagent',
        'ops': [
          {
            'op': 'set',
            'path': ['maxDepth'],
            'value': 3,
          },
          {
            'op': 'unset',
            'path': ['maxActiveSubagents'],
          },
        ],
        'expectedRevision': 0,
      });
    });

    test('a stale revision surfaces as settings/conflict', () async {
      host.handlers['settings/mutate'] = (_) => {
        'ok': false,
        'error': {
          'code': 'settings/conflict',
          'message': 'settings namespace "subagent" changed since it was read (expected revision 0, now 1)',
          'details': {'ns': 'subagent', 'expected': 0, 'actual': 1},
        },
      };
      final client = await connect();
      await expectLater(
        client.mutateSettingsView('subagent', [
          const SettingsOp.set(['maxDepth'], 4),
        ], expectedRevision: 0),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'settings/conflict')),
      );
    });

    test('plugin inventory: entries, row ids and preset compositions', () async {
      host.handlers['pluginInventory/list'] = (_) => ok(inventoryFixture());
      final inventory = await (await connect()).pluginInventory();
      expect(inventory.managementAvailable, isTrue);
      final loop = inventory.entries.firstWhere((e) => e.entryId == 'include:agent-loop');
      expect(loop.rowId, 'agent-loop');
      expect(loop.enabled, isTrue);
      expect(loop.fiberPhase, 'active');
      expect(loop.meta?.title?.resolve(), isNotEmpty);
      final off = inventory.entries.firstWhere((e) => !e.enabled);
      expect(off.fiberPhase, isNull);
      expect(inventory.presets.map((p) => p.id), ['standard', 'ptc']);
      expect(inventory.presets.first.isDefault, isTrue);
      final bash = inventory.presets.first.rows.firstWhere((r) => r.entryId == 'tool-bash');
      expect(bash.condition, contains('win32'));

      final fallback = PluginInventory.fromEntries(const [
        PluginEntry(entryId: 'include:x', moduleName: 'x', enabled: true, fiberPhase: 'failed'),
      ]);
      expect(fallback.entries.single.rowId, 'x');
      expect(fallback.presets, isEmpty);
    });
  });
}
