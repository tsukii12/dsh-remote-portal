import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

PluginBundle _bundle(String name, {bool official = false, bool installed = true, List<String> rows = const []}) =>
    PluginBundle.fromJson({
      'name': name,
      'official': official,
      'version': '1.2.0',
      'enabled': true,
      'installed': installed,
      'rows': [
        for (final row in rows) {'rowId': row, 'moduleName': name, 'entryId': 'include:$row'},
      ],
    });

SettingsNamespaceView _ns(String ns, {bool autoGenerate = true, bool fields = true}) => SettingsNamespaceView.fromJson({
  'ns': ns,
  'autoGenerate': autoGenerate,
  'schema': {
    'type': 'object',
    'dict': {
      if (fields) 'enabled': {'type': 'boolean'},
    },
  },
  'value': {'enabled': true},
  'revision': 1,
});

final _bundles = [
  _bundle('dsh-pet', rows: ['pet', 'pet-voice', 'pet-hidden']),
  _bundle('dsh-cost-meter', rows: ['cost-meter']),
  _bundle('novel-writer', rows: ['novel-writer']),
  _bundle('@deepseek-ai/dsh-experimental-cot-translation-bundle', official: true, rows: ['cot-translation']),
];

final _boot = WebBootGraph.fromJson({
  'rev': 'g1',
  'release': {'version': '0.2.1-rc.2'},
  'entries': [
    {'id': 'dsh-pet', 'rev': 'p1'},
    {'id': 'dsh-cost-meter', 'rev': 'c1'},
    {'id': '@deepseek-ai/dsh-experimental-cot-translation-bundle', 'rev': 'o1'},
  ],
})!;

BridgeInventory _bridge({String bootRev = 'g1', bool table = true}) => BridgeInventory.fromJson({
  'bootRev': bootRev,
  'routeGuard': true,
  if (table)
    'slots': {
      'settings.section': [
        {'package': '@deepseek-ai/dsh-client-ui-settings-general', 'cell': 'general'},
        {
          'package': 'dsh-pet',
          'cell': 'pet',
          'order': 40,
          'label': {'en': 'Desktop pet', 'zh': '桌宠'},
        },
      ],
      'plugins.bundle.config': [
        {'package': 'dsh-cost-meter', 'cell': 'dsh-cost-meter'},
      ],
    },
})!;

void main() {
  group('SeatInventory.from', () {
    test('drawable namespaces follow describe: autoGenerate and fields', () {
      final inventory = SeatInventory.from(
        ClientInventory.combine(bundles: _bundles, boot: _boot),
        namespaces: {
          'pet': _ns('pet'),
          'pet-voice': _ns('pet-voice', autoGenerate: false),
          'pet-hidden': _ns('pet-hidden', fields: false),
          'cost-meter': _ns('cost-meter'),
        },
        webReachable: true,
      );
      final pet = inventory.infoOf('dsh-pet');
      expect(pet.configNamespaces, ['pet']);
      expect(pet.rowIds, ['pet', 'pet-voice', 'pet-hidden']);
      expect((pet.hasClient, pet.rev, pet.installed, pet.official, pet.version), (true, 'p1', true, false, '1.2.0'));
      expect(inventory.infoOf('dsh-cost-meter').configNamespaces, ['cost-meter']);
      expect(inventory.infoOf('novel-writer').configNamespaces, isEmpty, reason: 'not served by describe');
      expect(inventory.tier, ClientInventoryTier.boot);
      expect(inventory.release, '0.2.1-rc.2');
      expect(inventory.bootRev, 'g1');
      expect(inventory.webReachable, isTrue);
      expect(inventory.needsProbe, isFalse);
    });

    test('without describe nothing is drawable; unknown packages are assumed to have a client', () {
      final inventory = SeatInventory.from(ClientInventory.combine(bundles: _bundles, boot: _boot));
      expect(inventory.infoOf('dsh-pet').configNamespaces, isEmpty);
      final unknown = inventory.infoOf('cordis-run-7');
      expect(
        (unknown.package, unknown.hasClient, unknown.enabled, unknown.official),
        ('cordis-run-7', true, true, false),
      );
      expect(inventory.isOfficial('@deepseek-ai/anything'), isTrue);
      expect(inventory.isOfficial('@deepseek-ai/dsh-experimental-cot-translation-bundle'), isTrue);
      expect(inventory.isOfficial('dsh-pet'), isFalse);
    });

    test('occupancy labels in the app language, officials marked', () {
      final inventory = SeatInventory.from(ClientInventory.combine(bundles: _bundles, boot: _boot, bridge: _bridge()));
      final sections = inventory.occupancy!['settings.section']!;
      expect(sections.map((o) => (o.package, o.label, o.official)), [
        ('@deepseek-ai/dsh-client-ui-settings-general', null, true),
        ('dsh-pet', '桌宠', false),
      ]);
      expect(inventory.routeGuard, isTrue);
      expect(inventory.occupancyStale, isFalse);
    });
  });

  group('occupantsFor', () {
    test('Tier B, fresh: the reported table only', () {
      final inventory = SeatInventory.from(ClientInventory.combine(bundles: _bundles, boot: _boot, bridge: _bridge()));
      expect(inventory.occupantsFor('plugins.bundle.config').map((o) => (o.package, o.inferred)), [
        ('dsh-cost-meter', false),
      ]);
      expect(inventory.occupantsFor('main'), isEmpty);
      expect(inventory.occupantsFor('settings.section', package: 'dsh-pet').single.cell, 'pet');
      expect(inventory.occupantsFor('settings.section', cell: 'general').single.official, isTrue);
    });

    test('Tier B, stale or without a table: guesses join and a probe is due', () {
      final stale = SeatInventory.from(
        ClientInventory.combine(
          bundles: _bundles,
          boot: _boot,
          bridge: _bridge(bootRev: 'old'),
        ),
      );
      expect(stale.needsProbe, isTrue);
      expect(stale.occupantsFor('plugins.bundle.config').map((o) => (o.package, o.inferred)), [
        ('dsh-cost-meter', false),
        ('dsh-pet', true),
      ]);
      final empty = SeatInventory.from(
        ClientInventory.combine(bundles: _bundles, boot: _boot, bridge: _bridge(table: false)),
      );
      expect(empty.needsProbe, isTrue);
      expect(empty.occupantsFor('plugins.bundle.config').map((o) => o.package), ['dsh-pet', 'dsh-cost-meter']);
    });

    test('Tier A guesses: bundle pages and row configs of third-party packages with a client', () {
      final inventory = SeatInventory.from(ClientInventory.combine(bundles: _bundles, boot: _boot));
      expect(inventory.needsProbe, isFalse);
      final pages = inventory.occupantsFor('plugins.bundle.config');
      expect(pages.map((o) => (o.package, o.cell, o.inferred)), [
        ('dsh-pet', 'dsh-pet', true),
        ('dsh-cost-meter', 'dsh-cost-meter', true),
      ]);
      expect(inventory.occupantsFor('plugins.row.config', package: 'dsh-pet').map((o) => o.cell), [
        'dsh-pet#pet',
        'dsh-pet#pet-voice',
        'dsh-pet#pet-hidden',
      ]);
      expect(inventory.occupantsFor('plugins.row.config', cell: 'dsh-cost-meter#cost-meter'), hasLength(1));
      // Nothing to guess for slots a package list cannot name.
      expect(inventory.occupantsFor('settings.section'), isEmpty);
      expect(inventory.occupantsFor('conversation.input.dock'), isEmpty);
    });

    test('bundles only (relay): no browser halves, no guesses', () {
      final inventory = SeatInventory.from(ClientInventory.combine(bundles: _bundles));
      expect(inventory.occupantsFor('plugins.bundle.config'), isEmpty);
      expect(inventory.webReachable, isFalse);
    });
  });
}
