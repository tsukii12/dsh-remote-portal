import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// The boot graph as DSH 0.2.1-rc.2 serves it (`dsh-client-modules` graph,
/// trimmed), with a string that carries every character the scanner must
/// skip.
const _graph = {
  'rev': 'g1',
  'release': {'version': '0.2.1-rc.2', 'commit': '9f2c1d0'},
  'entries': [
    {
      'id': '@deepseek-ai/dsh-client-modules',
      'url': 'plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=a1',
      'rev': 'a1',
      'immediately': true,
    },
    {'id': '@deepseek-ai/dsh-client-ui-chat', 'url': 'plugins/??chat&rev=b2', 'rev': 'b2'},
    {
      'id': 'dsh-pet',
      'url': 'plugins/??dsh-pet/client.js&rev=p1',
      'rev': 'p1',
      'inject': ['@deepseek-ai/dsh-client-ui-renderer'],
      'external': ['react'],
    },
    {'id': 'dsh-cost-meter', 'url': 'plugins/??cost&rev=c1', 'rev': 'c1'},
  ],
  'batches': [
    {
      'phase': 'bootstrap',
      'url': 'plugins/??boot&rev=z',
      'rev': 'z',
      'entries': ['@deepseek-ai/dsh-client-modules'],
      'note': 'braces } { and "quotes" and </script> stay inside',
    },
  ],
};

/// What `dsh-host-webserver` renders for a `global` row: the JSON with `<`
/// escaped, after the module queue script and the batch scripts.
String _indexHtml(Object? graph, {String assignment = 'globalThis["__DSH_BOOT__"] = '}) {
  final json = jsonEncode(graph).replaceAll('<', r'<');
  return '<!doctype html><html><head><base href="./">'
      '<script>(()=>{const pendingQueue=[]\nwindow.__ModuleLoader__={mode:"queue",pendingQueue,'
      'load(registration){pendingQueue.push(registration)}}})()</script>'
      '<link rel="preload" as="script" href="plugins/??app&amp;rev=y">'
      '<script src="plugins/??boot&amp;rev=z"></script>'
      '<script>$assignment$json</script>'
      '<title>DSH</title></head><body><div id="root"></div>'
      '<script>(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()</script></body></html>';
}

Map<String, Object?> _bundle(
  String name, {
  bool official = false,
  bool enabled = true,
  bool installed = true,
  List<String> rows = const [],
}) => {
  'name': name,
  'official': official,
  'availability': installed ? 'profile' : 'installation',
  'version': '1.0.0',
  'enabled': enabled,
  'installed': installed,
  'rows': [
    for (final row in rows) {'rowId': row, 'moduleName': name, 'entryId': 'include:$row'},
  ],
};

final _bundles = [
  _bundle('dsh-pet', rows: ['pet', 'pet-voice']),
  _bundle('dsh-cost-meter', rows: ['cost-meter']),
  _bundle('novel-writer', rows: ['novel-writer']),
  _bundle('@deepseek-ai/dsh-experimental-session-search', official: true, installed: false, enabled: false),
];

const _bridge = {
  'v': 1,
  'release': {'version': '0.2.1-rc.2'},
  'bootRev': 'g1',
  'packages': [
    {
      'name': 'dsh-pet',
      'hasClient': true,
      'rev': 'p1',
      'panels': ['mood'],
      'pet': 'codex',
    },
  ],
  'slots': {
    'settings.section': [
      {'package': '@deepseek-ai/dsh-client-ui-settings-general', 'cell': 'general', 'order': 0},
      {
        'package': 'dsh-pet',
        'cell': 'pet',
        'order': 40,
        'label': {'en': 'Desktop pet', 'zh': '桌宠'},
      },
      {'package': 'dsh-go-bridge', 'cell': 'general', 'order': -1},
      {'cell': 'nameless'},
    ],
    'conversation.input.dock': [
      {'package': 'dsh-cost-meter', 'cell': 'cost', 'label': '用量'},
      {'package': 'novel-writer', 'cell': 'nw', 'official': true},
    ],
    '': [
      {'package': 'dsh-pet'},
    ],
  },
  'routeGuard': true,
};

void main() {
  group('parseWebBootGraph', () {
    test('reads the graph the 0.2.1-rc.2 webserver renders', () {
      final graph = parseWebBootGraph(_indexHtml(_graph))!;
      expect(graph.rev, 'g1');
      expect(graph.release, const WebBootRelease(version: '0.2.1-rc.2', commit: '9f2c1d0'));
      expect(graph.entries.map((e) => e.id), [
        '@deepseek-ai/dsh-client-modules',
        '@deepseek-ai/dsh-client-ui-chat',
        'dsh-pet',
        'dsh-cost-meter',
      ]);
      final pet = graph.entry('dsh-pet')!;
      expect(pet.rev, 'p1');
      expect(pet.inject, ['@deepseek-ai/dsh-client-ui-renderer']);
      expect(pet.external, ['react']);
      expect(pet.immediately, isFalse);
      expect(graph.entry('@deepseek-ai/dsh-client-modules')!.immediately, isTrue);
      expect(graph.packages, contains('dsh-cost-meter'));
    });

    test('accepts the other ways of writing the assignment', () {
      for (final assignment in [
        'window.__DSH_BOOT__=',
        'globalThis.__DSH_BOOT__ = ',
        "window['__DSH_BOOT__'] =",
        'self . __DSH_BOOT__\n=\n',
      ]) {
        expect(parseWebBootGraph(_indexHtml(_graph, assignment: assignment))?.rev, 'g1', reason: assignment);
      }
      // Statements after the literal on the same line.
      final trailing = _indexHtml(
        _graph,
        assignment: 'window.__DSH_BOOT__ = ',
      ).replaceFirst('</script><title>', ';window.__x = 1</script><title>');
      expect(parseWebBootGraph(trailing)?.rev, 'g1');
    });

    test('skips a declaration that is not a graph and takes the next one', () {
      final html = '<script>globalThis["__DSH_BOOT__"] = undefined</script>${_indexHtml(_graph)}';
      expect(parseWebBootGraph(html)?.rev, 'g1');
    });

    test('pages without a usable graph give null', () {
      expect(parseWebBootGraph('<html><body>DSH</body></html>'), isNull);
      expect(parseWebBootGraph(''), isNull);
      expect(parseWebBootGraph(_indexHtml({'rev': 'x'})), isNull, reason: 'no entries array');
      expect(parseWebBootGraph(_indexHtml(['not', 'an', 'object'])), isNull);
      // Cut off in the middle of the literal.
      final cut = _indexHtml(_graph);
      expect(parseWebBootGraph(cut.substring(0, cut.indexOf('dsh-pet'))), isNull);
      // A raw `<` outside a string: the script ended before the object did.
      expect(parseWebBootGraph('<script>window.__DSH_BOOT__ = {"rev": "x", </script><p>"entries": []}'), isNull);
      // Too large to search.
      expect(parseWebBootGraph(' ' * (webBootMaxPageBytes + 1) + _indexHtml(_graph)), isNull);
    });

    test('entries without an id are dropped, duplicates kept once', () {
      final graph = parseWebBootGraph(
        _indexHtml({
          'rev': 'r',
          'entries': [
            {'id': 'a', 'rev': '1'},
            {'url': 'x'},
            'junk',
            {'id': ''},
            {'id': 'a', 'rev': '2'},
            {'id': 'b'},
          ],
        }),
      )!;
      expect(graph.entries.map((e) => (e.id, e.rev)), [('a', '1'), ('b', '')]);
      expect(graph.release, isNull);
    });
  });

  group('BridgeInventory', () {
    test('reads occupants, resolves nothing, drops the bridge and nameless rows', () {
      final inventory = BridgeInventory.fromJson(_bridge)!;
      expect(inventory.version, 1);
      expect(inventory.bootRev, 'g1');
      expect(inventory.occupancyStale, isFalse, reason: 'older bridges may omit freshness');
      expect(inventory.routeGuard, isTrue);
      expect(inventory.release?.version, '0.2.1-rc.2');
      final pet = inventory.packages.single;
      expect((pet.name, pet.hasClient, pet.rev, pet.pet), ('dsh-pet', true, 'p1', 'codex'));
      expect(pet.panels, ['mood']);
      final sections = inventory.slots!['settings.section']!;
      expect(sections.map((o) => (o.package, o.cell, o.order)), [
        ('@deepseek-ai/dsh-client-ui-settings-general', 'general', 0),
        ('dsh-pet', 'pet', 40),
      ]);
      expect(sections[1].label?.resolve('zh'), '桌宠');
      expect(sections[1].label?.resolve('en'), 'Desktop pet');
      expect(inventory.slots!['conversation.input.dock']!.first.label?.resolve(), '用量');
      expect(inventory.slots!.containsKey(''), isFalse);
    });

    test('no table yet, no guard, not an object', () {
      final empty = BridgeInventory.fromJson({'bootRev': 'g1'})!;
      expect(empty.slots, isNull);
      expect(empty.routeGuard, isFalse);
      expect(empty.packages, isEmpty);
      expect(BridgeInventory.fromJson('nope'), isNull);
      expect(BridgeInventory.fromJson(null), isNull);
    });

    test('reads the bridge freshness signal independently of the reported boot rev', () {
      final inventory = BridgeInventory.fromJson({
        ..._bridge,
        'currentRev': 'g2',
        'occupancy': {'stale': true},
      })!;
      expect(inventory.bootRev, 'g1');
      expect(inventory.occupancyStale, isTrue);
      expect(inventory.slots, isNotNull);
      final fresh = BridgeInventory.fromJson({
        ..._bridge,
        'currentRev': 'g1',
        'occupancy': {'stale': false},
      })!;
      expect(fresh.occupancyStale, isFalse);
    });
  });

  group('ClientInventory.combine', () {
    final bundles = _bundles.map(PluginBundle.fromJson).toList();
    final boot = WebBootGraph.fromJson(_graph)!;
    final bridge = BridgeInventory.fromJson(_bridge)!;

    test('bundles only: nothing known about browser halves', () {
      final inventory = ClientInventory.combine(bundles: bundles);
      expect(inventory.tier, ClientInventoryTier.bundles);
      expect(inventory.clientsKnown, isFalse);
      expect(inventory.packages.keys, [
        'dsh-pet',
        'dsh-cost-meter',
        'novel-writer',
        '@deepseek-ai/dsh-experimental-session-search',
      ]);
      expect(inventory.packages.values.any((p) => p.hasClient), isFalse);
      expect(inventory.slots, isNull);
      expect(inventory.occupancyStale, isFalse);
      expect(inventory.routeGuard, isFalse);
      expect(inventory.packages['dsh-pet']!.rowIds, ['pet', 'pet-voice']);
    });

    test('Tier A: the boot graph says who has a browser half', () {
      final inventory = ClientInventory.combine(bundles: bundles, boot: boot);
      expect(inventory.tier, ClientInventoryTier.boot);
      expect(inventory.clientsKnown, isTrue);
      expect(inventory.bootRev, 'g1');
      expect(inventory.release?.commit, '9f2c1d0');
      final pet = inventory.packages['dsh-pet']!;
      expect((pet.hasClient, pet.rev, pet.official, pet.enabled, pet.installed), (true, 'p1', false, true, true));
      expect(inventory.packages['novel-writer']!.hasClient, isFalse);
      // Client packages that are no bundle are listed after the bundles.
      final chat = inventory.packages['@deepseek-ai/dsh-client-ui-chat']!;
      expect((chat.hasClient, chat.official, chat.enabled, chat.installed), (true, true, true, false));
      expect(inventory.packages.keys.last, '@deepseek-ai/dsh-client-ui-chat');
      expect(inventory.isOfficial('@deepseek-ai/dsh-experimental-session-search'), isTrue);
      expect(inventory.isOfficial('dsh-cost-meter'), isFalse);
      expect(inventory.isOfficial('dsh-go-bridge'), isTrue);
      expect(inventory.isOfficial('@deepseek-ai/never-heard-of'), isTrue);
      expect(inventory.slots, isNull);
    });

    test('Tier B: occupancy with officials marked, fresh for the same boot rev', () {
      final inventory = ClientInventory.combine(bundles: bundles, boot: boot, bridge: bridge);
      expect(inventory.tier, ClientInventoryTier.bridge);
      expect(inventory.occupancyStale, isFalse);
      expect(inventory.routeGuard, isTrue);
      final sections = inventory.slots!['settings.section']!;
      expect(sections.map((o) => (o.package, o.official)), [
        ('@deepseek-ai/dsh-client-ui-settings-general', true),
        ('dsh-pet', false),
      ]);
      final dock = inventory.slots!['conversation.input.dock']!;
      expect(dock.map((o) => (o.package, o.official)), [('dsh-cost-meter', false), ('novel-writer', true)]);
      final pet = inventory.packages['dsh-pet']!;
      expect(pet.panels, ['mood']);
      expect(pet.pet, 'codex');
    });

    test('Tier B is stale on another boot rev, without a table or rev', () {
      final moved = WebBootGraph.fromJson({..._graph, 'rev': 'g2'})!;
      expect(ClientInventory.combine(bundles: bundles, boot: moved, bridge: bridge).occupancyStale, isTrue);
      final noTable = BridgeInventory.fromJson({'bootRev': 'g1', 'routeGuard': true})!;
      expect(ClientInventory.combine(boot: boot, bridge: noTable).occupancyStale, isTrue);
      final noRev = BridgeInventory.fromJson({'slots': <String, Object?>{}})!;
      expect(ClientInventory.combine(boot: boot, bridge: noRev).occupancyStale, isTrue);
    });

    test('Tier B without the page: the bridge fills in browser halves and rev', () {
      final inventory = ClientInventory.combine(bundles: bundles, bridge: bridge);
      expect(inventory.tier, ClientInventoryTier.bridge);
      expect(inventory.bootRev, 'g1');
      expect(inventory.occupancyStale, isFalse);
      expect(inventory.packages['dsh-pet']!.hasClient, isTrue);
      expect(inventory.packages['dsh-cost-meter']!.hasClient, isFalse);
    });

    test('reported stale occupancy stays stale with an unavailable or earlier page', () {
      final stale = BridgeInventory.fromJson({
        ..._bridge,
        'currentRev': 'g2',
        'occupancy': {'stale': true},
      })!;
      for (final page in <WebBootGraph?>[null, boot]) {
        final inventory = ClientInventory.combine(bundles: bundles, boot: page, bridge: stale);
        expect(inventory.tier, ClientInventoryTier.bridge);
        expect(inventory.occupancyStale, isTrue);
        expect(inventory.slots, isNotEmpty, reason: 'retain the report while asking for a refresh');
        expect(inventory.routeGuard, isTrue);
      }
      final refreshed = BridgeInventory.fromJson({
        ..._bridge,
        'bootRev': 'g2',
        'currentRev': 'g2',
        'occupancy': {'stale': false},
      })!;
      expect(ClientInventory.combine(bridge: refreshed).occupancyStale, isFalse);
      final currentPage = WebBootGraph.fromJson({..._graph, 'rev': 'g2'})!;
      expect(ClientInventory.combine(boot: currentPage, bridge: refreshed).occupancyStale, isFalse);
    });

    test('a fresh bridge report does not override a different page rev', () {
      final fresh = BridgeInventory.fromJson({
        ..._bridge,
        'currentRev': 'g1',
        'occupancy': {'stale': false},
      })!;
      final moved = WebBootGraph.fromJson({..._graph, 'rev': 'g2'})!;
      expect(ClientInventory.combine(boot: moved, bridge: fresh).occupancyStale, isTrue);
      expect(ClientInventory.combine(boot: boot, bridge: fresh).occupancyStale, isFalse);
    });
  });

  group('calls', () {
    late _FakeHost host;
    late DshClient client;

    setUp(() async {
      host = await _FakeHost.start();
      client = await DshClient.connect(baseUri: host.baseUri, token: _FakeHost.token, startMux: false);
    });

    tearDown(() async {
      await client.close();
      await host.close();
    });

    test('readWebBoot sends the cookie and parses the page', () async {
      expect(client.canReadWebBoot, isTrue);
      final graph = await client.readWebBoot();
      expect(graph?.rev, 'g1');
      final index = host.requests.lastWhere((r) => r.path == '/');
      expect(index.cookie, contains('${_FakeHost.cookieName}=v1'));
      expect(index.query, isEmpty, reason: 'the launch token is only used to log in');
    });

    test('readWebBoot: page without a graph, refused page', () async {
      host.index = '<html><body>maintenance</body></html>';
      expect(await client.readWebBoot(), isNull);
      host.indexStatus = 401;
      await expectLater(
        client.readWebBoot(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/http-401')),
      );
    });

    test('readBridgeInventory: missing bridge, table, bad body, refusal', () async {
      expect(await client.readBridgeInventory(), isNull);
      host.bridge = _bridge;
      final inventory = await client.readBridgeInventory();
      expect(inventory?.slots?['settings.section']?.length, 2);
      expect(host.requests.last.cookie, contains(_FakeHost.cookieName));
      host.bridgeBody = '<html>not json</html>';
      await expectLater(client.readBridgeInventory(), throwsA(isA<DshProtocolException>()));
      host.bridgeBody = null;
      host.bridgeStatus = 403;
      await expectLater(
        client.readBridgeInventory(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/http-403')),
      );
    });

    test('inventory success and non-404 failures keep one request and existing error codes', () async {
      host.bridge = _bridge;
      host.requests.clear();
      expect((await client.readBridgeInventory())?.bootRev, 'g1');
      expect(host.requests.map((r) => r.path), [bridgeInventoryPath]);
      for (final status in [401, 403, 503]) {
        host.bridgeStatus = status;
        host.bridgeBody = jsonEncode({
          'error': {'code': 'unavailable', 'message': 'try later'},
        });
        host.requests.clear();
        await expectLater(
          client.readBridgeInventory(),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/http-$status')),
        );
        expect(host.requests.map((r) => r.path), [bridgeInventoryPath]);
      }
    });

    test('inventory resource 404 keeps nested or legacy flat errors without negotiation', () async {
      host.bridgeStatus = 404;
      for (final body in [
        {
          'error': {'code': 'not-found', 'message': 'table missing'},
        },
        {'code': 'not-found', 'message': 'table missing'},
        {
          'error': {'code': 'not-found', 'message': 'table missing'},
          'code': 'route-not-found',
          'message': 'stale alias',
        },
      ]) {
        host.bridgeBody = jsonEncode(body);
        host.requests.clear();
        await expectLater(
          client.readBridgeInventory(),
          throwsA(
            isA<DshRemoteException>()
                .having((e) => e.code, 'code', 'client-inventory/not-found')
                .having((e) => e.message, 'message', 'table missing')
                .having((e) => e.details, 'details', {'path': bridgeInventoryPath, 'status': 404}),
          ),
        );
        expect(host.requests.map((r) => r.path), [bridgeInventoryPath]);
      }
    });

    test('an explicit missing inventory route needs no capability request', () async {
      host.bridgeStatus = 404;
      for (final body in [
        {
          'error': {'code': 'route-not-found', 'message': 'route missing'},
        },
        {'code': 'route-not-found', 'message': 'route missing'},
      ]) {
        host.bridgeBody = jsonEncode(body);
        host.requests.clear();
        expect(await client.readBridgeInventory(), isNull);
        expect(host.requests.map((r) => r.path), [bridgeInventoryPath]);
      }
    });

    test('ambiguous inventory 404 uses fresh capabilities and keeps legacy fallback', () async {
      host.bridgeStatus = 404;
      host.bridgeBody = '<html>not found</html>';
      host.requests.clear();
      expect(await client.readBridgeInventory(), isNull);
      expect(host.requests.map((r) => r.path), [bridgeInventoryPath, dshGoCapabilitiesPath]);
      for (final capabilities in [
        <String>[],
        ['future-capability'],
        ['inventory'],
        <String>[],
      ]) {
        host.capabilities = {'v': 1, 'bridge': '999.0.0', 'capabilities': capabilities};
        host.requests.clear();
        if (capabilities.contains('inventory')) {
          await expectLater(
            client.readBridgeInventory(),
            throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/http-404')),
          );
        } else {
          expect(await client.readBridgeInventory(), isNull);
        }
        expect(host.requests.map((r) => r.path), [bridgeInventoryPath, dshGoCapabilitiesPath]);
        expect(host.requests.every((r) => r.cookie?.contains(_FakeHost.cookieName) ?? false), isTrue);
        expect(host.requests.every((r) => r.query.isEmpty), isTrue);
      }
    });

    test('inventory negotiation failures propagate instead of becoming an absent bridge', () async {
      host.bridgeStatus = 404;
      for (final status in [401, 403, 503]) {
        host.capabilitiesStatus = status;
        await expectLater(
          client.readBridgeInventory(),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/http-$status')),
        );
      }
      host.capabilitiesStatus = 404;
      host.capabilitiesBody = jsonEncode({
        'error': {'code': 'not-found', 'message': 'resource missing'},
      });
      await expectLater(
        client.readBridgeInventory(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/not-found')),
      );
      host.capabilitiesBody = jsonEncode({
        'error': {'code': 'route-not-found', 'message': 'route missing'},
      });
      expect(await client.readBridgeInventory(), isNull);
      host.capabilitiesStatus = null;
      host.capabilitiesBody = null;
      host.capabilities = {'v': 2};
      await expectLater(
        client.readBridgeInventory(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/unsupported-version')),
      );
      host.capabilities = {'v': 1, 'bridge': '0.4.0'};
      await expectLater(client.readBridgeInventory(), throwsA(isA<DshProtocolException>()));
      host.capabilitiesBody = '<html>not json</html>';
      await expectLater(client.readBridgeInventory(), throwsA(isA<DshProtocolException>()));
    });

    test('combined inventory keeps its documented best-effort treatment of optional failures', () async {
      host.bridgeStatus = 404;
      host.bridgeBody = jsonEncode({
        'error': {'code': 'not-found', 'message': 'table missing'},
      });
      host.requests.clear();
      expect((await client.readClientInventory()).tier, ClientInventoryTier.boot);
      expect(host.requests.where((r) => r.path == dshGoCapabilitiesPath), isEmpty);
    });

    test('combined inventory retains bridge freshness with an earlier or unavailable page', () async {
      host.bridge = {
        ..._bridge,
        'currentRev': 'g2',
        'occupancy': {'stale': true},
      };
      for (final pageStatus in [200, 503]) {
        host.indexStatus = pageStatus;
        host.requests.clear();
        final inventory = await client.readClientInventory();
        expect(inventory.tier, ClientInventoryTier.bridge);
        expect(inventory.occupancyStale, isTrue);
        expect(host.requests.where((r) => r.path == bridgeInventoryPath).length, 1);
        expect(host.requests.where((r) => r.path == dshGoCapabilitiesPath), isEmpty);
      }
      host.bridge = {
        ..._bridge,
        'bootRev': 'g2',
        'currentRev': 'g2',
        'occupancy': {'stale': false},
      };
      expect((await client.readClientInventory()).occupancyStale, isFalse);
    });

    test('readClientInventory climbs to the tier the Host offers', () async {
      var inventory = await client.readClientInventory();
      expect(inventory.tier, ClientInventoryTier.boot);
      expect(inventory.packages['dsh-pet']?.hasClient, isTrue);

      host.bridge = _bridge;
      inventory = await client.readClientInventory();
      expect(inventory.tier, ClientInventoryTier.bridge);
      expect(inventory.routeGuard, isTrue);

      // A broken page and a broken bridge only lower the tier.
      host.indexStatus = 500;
      host.bridgeStatus = 500;
      inventory = await client.readClientInventory();
      expect(inventory.tier, ClientInventoryTier.bundles);
      expect(inventory.packages.keys, contains('novel-writer'));
    });

    test('the bundle list is required', () async {
      host.failBundles = true;
      await expectLater(client.readClientInventory(), throwsA(isA<DshRemoteException>()));
    });
  });

  group('carrier without pages (relay)', () {
    test('bundles only, page reads refused', () async {
      final client = DshClient.withCarrier(_RelayCarrier());
      addTearDown(client.close);
      expect(client.canReadWebBoot, isFalse);
      final inventory = await client.readClientInventory();
      expect(inventory.tier, ClientInventoryTier.bundles);
      expect(inventory.packages.keys, contains('dsh-pet'));
      await expectLater(
        client.readWebBoot(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/unsupported')),
      );
      await expectLater(
        client.readBridgeInventory(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'client-inventory/unsupported')),
      );
    });
  });
}

class _Request {
  _Request(this.method, this.path, this.query, this.cookie);
  final String method;
  final String path;
  final Map<String, String> query;
  final String? cookie;
}

/// `dsh web` as far as these calls go: launch-token login, cookie check on
/// the index page, `pluginManager/listBundles`, and an optional bridge route.
class _FakeHost {
  _FakeHost._(this._server);

  static const token = 'launch-token';
  static const cookieName = 'dsh-auth-k1';

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((request) => unawaited(host._handle(request)));
    return host;
  }

  final HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');
  final requests = <_Request>[];

  String index = _indexHtml(_graph);
  int indexStatus = 200;
  Map<String, Object?>? bridge;
  String? bridgeBody;
  int? bridgeStatus;
  Map<String, Object?>? capabilities;
  String? capabilitiesBody;
  int? capabilitiesStatus;
  bool failBundles = false;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final cookie = request.headers.value(HttpHeaders.cookieHeader);
    requests.add(_Request(request.method, request.uri.path, request.uri.queryParameters, cookie));
    final response = request.response;
    final authed = cookie?.contains('$cookieName=v1.sig') ?? false;
    switch (request.uri.path) {
      case '/' when request.uri.queryParameters['token'] == token:
        response
          ..statusCode = 303
          ..headers.set('location', './')
          ..headers.add('set-cookie', '$cookieName=v1.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict');
      case '/':
        response.statusCode = authed ? indexStatus : 401;
        response.headers.contentType = ContentType.html;
        if (authed && indexStatus == 200) response.write(index);
      case bridgeInventoryPath:
        if (!authed) {
          response.statusCode = 401;
        } else if (bridgeStatus case final status?) {
          response.statusCode = status;
          if (bridgeBody case final body?) response.write(body);
        } else if (bridgeBody case final body?) {
          response.write(body);
        } else if (bridge case final table?) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(table));
        } else {
          response.statusCode = 404;
        }
      case dshGoCapabilitiesPath:
        if (!authed) {
          response.statusCode = 401;
        } else {
          response.statusCode = capabilitiesStatus ?? (capabilities == null && capabilitiesBody == null ? 404 : 200);
          if (capabilitiesBody case final body?) {
            response.write(body);
          } else if (capabilities case final snapshot?) {
            response.headers.contentType = ContentType.json;
            response.write(jsonEncode(snapshot));
          }
        }
      case '/api/pluginManager/listBundles':
        final envelope = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': failBundles
                ? {
                    'ok': false,
                    'error': {'code': 'plugin-manager/unavailable', 'message': 'off', 'details': {}},
                  }
                : {'ok': true, 'value': _bundles},
          }),
        );
      default:
        response.statusCode = 404;
    }
    await response.close();
  }
}

/// The relay tunnel as these calls see it: RPC only.
class _RelayCarrier extends DshCarrier {
  @override
  String get kind => 'remote-relay';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      endpoint == 'pluginManager/listBundles'
      ? RpcOk(_bundles)
      : RpcError(DshRemoteException('gateway/method-not-allowed', endpoint));

  @override
  Future<DshMuxLink> openLink(MuxOptions options) =>
      throw const DshCarrierRefusedException('TEST', 'no mux in this test');

  @override
  Future<void> close() async {}
}
