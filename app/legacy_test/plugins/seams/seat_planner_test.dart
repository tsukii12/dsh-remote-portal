import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart' show ClientInventoryTier;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _ssh = HostRef.portal('box');

/// Draws [slots] for packages listed in [packages].
class _FakeAdapter implements NativeSlotAdapter {
  _FakeAdapter(this.id, this.slots, {this.packages = const {}, this.partial = false});

  @override
  final String id;
  @override
  final Set<String> slots;
  final Set<String> packages;
  final bool partial;

  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => packages.contains(info.package);

  @override
  NativeCoverage coverage(SlotOccupant o) => partial ? NativeCoverage.partial : NativeCoverage.full;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) => Text('$id ${o.package}');
}

/// Refuses the islands whose key is listed.
class _VetoBudget implements IslandBudget {
  _VetoBudget(this.refused);
  final Set<String> refused;
  final asked = <IslandSpec>[];

  @override
  bool canOpen(IslandSpec spec) {
    asked.add(spec);
    return !refused.contains(spec.key);
  }
}

SlotOccupant _o(
  String slot,
  String package, {
  String cell = '',
  int order = 0,
  bool official = false,
  bool inferred = false,
}) => SlotOccupant(slot: slot, package: package, cell: cell, order: order, official: official, inferred: inferred);

SeatContext _seat({
  HostRef host = _ssh,
  SeatPlacement placement = SeatPlacement.page,
  String? sessionId,
  bool web = true,
}) => SeatContext(host: host, placement: placement, sessionId: sessionId, webAvailable: web);

SeatInventory _inventory({
  ClientInventoryTier tier = ClientInventoryTier.bridge,
  bool routeGuard = false,
  Map<String, PluginClientInfo> packages = const {},
}) => SeatInventory(tier: tier, routeGuard: routeGuard, packages: packages, webReachable: true);

void main() {
  final registry = SlotAdapterRegistry();

  List<SeatItem> plan(
    String slot,
    List<SlotOccupant> occupants, {
    SeatContext? seat,
    IslandBudget budget = const OpenIslandBudget(),
    SeatOverrides overrides = SeatOverrides.none,
    SeatInventory? inventory,
    SlotAdapterRegistry? using,
  }) => (using ?? registry).plan(
    slot,
    occupants,
    seat ?? _seat(),
    budget: budget,
    overrides: overrides,
    inventory: inventory ?? _inventory(),
  );

  List<(SeatMode, String)> modes(List<SeatItem> items) => [for (final i in items) (i.mode, i.occupant.package)];

  group('filtering and order', () {
    test('official occupants, other slots and repeated cells are dropped', () {
      final items = plan(
        Slots.settingsSection,
        [
          _o(Slots.settingsSection, '@deepseek-ai/dsh-client-ui-settings-general', cell: 'general'),
          _o(Slots.settingsSection, 'official-by-flag', cell: 'x', official: true),
          _o(Slots.settingsSection, 'dsh-go-bridge', cell: 'general'),
          _o(Slots.bundleConfig, 'dsh-pet', cell: 'dsh-pet'),
          _o(Slots.settingsSection, 'dsh-pet', cell: 'pet'),
          _o(Slots.settingsSection, 'dsh-pet', cell: 'pet', order: 9),
          _o(Slots.settingsSection, 'listed-official', cell: 'y'),
        ],
        inventory: _inventory(
          packages: {'listed-official': const PluginClientInfo(package: 'listed-official', official: true)},
        ),
      );
      expect(items.map((i) => (i.occupant.package, i.occupant.cell)), [('dsh-pet', 'pet')]);
    });

    test('by order, reported order on ties', () {
      final items = plan(Slots.settingsSection, [
        _o(Slots.settingsSection, 'c', cell: 'c', order: 5),
        _o(Slots.settingsSection, 'a', cell: 'a', order: 1),
        _o(Slots.settingsSection, 'z', cell: 'z', order: 5),
        _o(Slots.settingsSection, 'b', cell: 'b', order: -3),
      ]);
      expect(items.map((i) => i.occupant.package), ['b', 'a', 'c', 'z']);
    });

    test('replacement points of the native UI plan to nothing', () {
      for (final slot in [
        'root',
        'sidebar',
        'conversation.header',
        'conversation.composer.bar',
        'shell.leading',
        'settings.trigger',
      ]) {
        expect(plan(slot, [_o(slot, 'skin-plugin')]), isEmpty, reason: slot);
      }
    });

    test('an unknown slot (newer DSH) gets a web entry only', () {
      expect(modes(plan('conversation.brand.new', [_o('conversation.brand.new', 'p', cell: 'x')])), [
        (SeatMode.webLink, 'p'),
      ]);
    });
  });

  group('native, island, web, hidden', () {
    test('a native adapter wins; then island; then web entry', () {
      final using = SlotAdapterRegistry([
        _FakeAdapter('form', {Slots.settingsSection}, packages: {'native-pkg'}),
      ]);
      final items = plan(Slots.settingsSection, [
        _o(Slots.settingsSection, 'native-pkg', cell: 'n'),
        _o(Slots.settingsSection, 'web-pkg', cell: 'w'),
      ], using: using);
      expect(modes(items), [(SeatMode.native, 'native-pkg'), (SeatMode.island, 'web-pkg')]);
      expect(items.first.adapter?.id, 'form');
      final spec = items.last.island!;
      expect(
        (spec.host, spec.form, spec.slot, spec.cell, spec.package, spec.sessionId, spec.maskOfficial),
        (_ssh, IslandForm.page, Slots.settingsSection, 'w', 'web-pkg', null, false),
      );
    });

    test('no budget: web entry; no web on this host: hidden', () {
      final occupants = [_o(Slots.settingsSection, 'p', cell: 'x')];
      expect(modes(plan(Slots.settingsSection, occupants, budget: const NoIslandBudget())), [(SeatMode.webLink, 'p')]);
      expect(modes(plan(Slots.settingsSection, occupants, seat: _seat(web: false))), [(SeatMode.hidden, 'p')]);
    });

    test('the budget is asked per spec and can refuse one', () {
      final budget = _VetoBudget({'ssh|box|page|settings.section|b|'});
      final items = plan(Slots.settingsSection, [
        _o(Slots.settingsSection, 'a', cell: 'a'),
        _o(Slots.settingsSection, 'b', cell: 'b'),
      ], budget: budget);
      expect(modes(items), [(SeatMode.island, 'a'), (SeatMode.webLink, 'b')]);
      expect(budget.asked.map((s) => s.cell), ['a', 'b']);
    });

    test('a row never hosts an island', () {
      final items = plan(Slots.settingsSection, [
        _o(Slots.settingsSection, 'p', cell: 'x'),
      ], seat: _seat(placement: SeatPlacement.row));
      expect(modes(items), [(SeatMode.webLink, 'p')]);
    });

    test('the local engine gets islands only behind the route guard', () {
      final occupants = [_o(Slots.settingsSection, 'p', cell: 'x')];
      final local = _seat(host: HostRef.none);
      expect(modes(plan(Slots.settingsSection, occupants, seat: local)), [(SeatMode.webLink, 'p')]);
      expect(modes(plan(Slots.settingsSection, occupants, seat: local, inventory: _inventory(routeGuard: true))), [
        (SeatMode.island, 'p'),
      ]);
    });

    test('a page island needs a known cell; a session slot needs the session', () {
      expect(modes(plan(Slots.settingsSection, [_o(Slots.settingsSection, 'p')])), [(SeatMode.webLink, 'p')]);
      final tab = [_o(Slots.rightPaneTab, 'p', cell: 'p-tab')];
      expect(modes(plan(Slots.rightPaneTab, tab)), [(SeatMode.webLink, 'p')]);
      final items = plan(Slots.rightPaneTab, tab, seat: _seat(sessionId: 's1'));
      expect(items.single.island?.sessionId, 's1');
      // Root slots do not carry the session into the island.
      final root = plan(Slots.settingsSection, [
        _o(Slots.settingsSection, 'p', cell: 'x'),
      ], seat: _seat(sessionId: 's1'));
      expect(root.single.island?.sessionId, isNull);
    });

    test('message-level slots get web entries only', () {
      final items = plan('conversation.chat.turnTail', [
        _o('conversation.chat.turnTail', 'p', cell: 'x'),
      ], seat: _seat(sessionId: 's'));
      expect(modes(items), [(SeatMode.webLink, 'p')]);
    });
  });

  group('ui.json overrides', () {
    final using = SlotAdapterRegistry([
      _FakeAdapter('form', {Slots.settingsSection}, packages: {'p'}),
    ]);
    final occupants = [_o(Slots.settingsSection, 'p', cell: 'x')];
    SeatOverrides ov(SeatOverride value) => SeatOverrides({
      Slots.settingsSection: {'p': value},
    });

    test('hidden, web, island, native', () {
      expect(modes(plan(Slots.settingsSection, occupants, using: using, overrides: ov(SeatOverride.hidden))), [
        (SeatMode.hidden, 'p'),
      ]);
      expect(modes(plan(Slots.settingsSection, occupants, using: using, overrides: ov(SeatOverride.web))), [
        (SeatMode.webLink, 'p'),
      ]);
      expect(modes(plan(Slots.settingsSection, occupants, using: using, overrides: ov(SeatOverride.island))), [
        (SeatMode.island, 'p'),
      ]);
      expect(modes(plan(Slots.settingsSection, occupants, using: using, overrides: ov(SeatOverride.native))), [
        (SeatMode.native, 'p'),
      ]);
    });

    test('native without an adapter falls back to the usual order', () {
      expect(modes(plan(Slots.settingsSection, occupants, overrides: ov(SeatOverride.native))), [
        (SeatMode.island, 'p'),
      ]);
    });

    test('an override for another package or slot changes nothing', () {
      final other = SeatOverrides({
        Slots.settingsSection: {'q': SeatOverride.hidden},
        Slots.main: {'p': SeatOverride.hidden},
      });
      expect(modes(plan(Slots.settingsSection, occupants, using: using, overrides: other)), [(SeatMode.native, 'p')]);
    });
  });

  group('partial native coverage', () {
    final using = SlotAdapterRegistry([
      _FakeAdapter('cordis', {Slots.cordisView}, packages: {'p'}, partial: true),
    ]);
    final occupants = [_o(Slots.cordisView, 'p', cell: 'run-1')];

    test('the native list, then the island for the rest', () {
      final items = plan(
        Slots.cordisView,
        occupants,
        using: using,
        seat: _seat(sessionId: 's'),
      );
      expect(modes(items), [(SeatMode.native, 'p'), (SeatMode.island, 'p')]);
      expect(items.last.island?.cell, 'run-1');
    });

    test('a web entry for the rest without islands, nothing without web', () {
      expect(
        modes(
          plan(
            Slots.cordisView,
            occupants,
            using: using,
            seat: _seat(sessionId: 's'),
            budget: const NoIslandBudget(),
          ),
        ),
        [(SeatMode.native, 'p'), (SeatMode.webLink, 'p')],
      );
      expect(
        modes(
          plan(
            Slots.cordisView,
            occupants,
            using: using,
            seat: _seat(sessionId: 's', web: false),
          ),
        ),
        [(SeatMode.native, 'p')],
      );
    });

    test('pinned native: the list only', () {
      final items = plan(
        Slots.cordisView,
        occupants,
        using: using,
        seat: _seat(sessionId: 's'),
        overrides: const SeatOverrides({
          Slots.cordisView: {'p': SeatOverride.native},
        }),
      );
      expect(modes(items), [(SeatMode.native, 'p')]);
    });

    test('the standard Cordis adapter is partial and always matches', () {
      final items = plan(
        Slots.cordisView,
        occupants,
        using: SlotAdapterRegistry.standard(),
        seat: _seat(sessionId: 's'),
      );
      expect(modes(items), [(SeatMode.native, 'p'), (SeatMode.island, 'p')]);
      expect(items.first.adapter, isA<CordisAdapter>());
    });
  });

  group('panel islands and masking', () {
    final dock = [_o(Slots.inputDock, 'cost', cell: 'cost'), _o(Slots.inputDock, 'mood', cell: 'mood')];
    final panel = _seat(placement: SeatPlacement.panel, sessionId: 's');

    test('Tier B: every occupant shares one masked panel island', () {
      final items = plan(Slots.inputDock, dock, seat: panel);
      expect(modes(items), [(SeatMode.island, 'cost'), (SeatMode.island, 'mood')]);
      expect(items[0].island, items[1].island);
      final spec = items[0].island!;
      expect(
        (spec.form, spec.cell, spec.package, spec.maskOfficial, spec.sessionId),
        (IslandForm.panel, null, null, true, 's'),
      );
    });

    test('Tier A cannot hide official entries: web entries', () {
      final items = plan(
        Slots.inputDock,
        dock,
        seat: panel,
        inventory: _inventory(tier: ClientInventoryTier.boot),
      );
      expect(items.map((i) => i.mode).toSet(), {SeatMode.webLink});
    });

    test('a masked page (general settings) needs Tier B and a reported occupant', () {
      final item = [_o(Slots.generalItem, 'p', cell: 'row')];
      expect(plan(Slots.generalItem, item).single.island?.maskOfficial, isTrue);
      expect(
        plan(Slots.generalItem, item, inventory: _inventory(tier: ClientInventoryTier.boot)).single.mode,
        SeatMode.webLink,
      );
      final guessed = [_o(Slots.generalItem, 'p', cell: 'row', inferred: true)];
      expect(plan(Slots.generalItem, guessed).single.mode, SeatMode.webLink);
    });

    test('overlay islands only on request', () {
      final pet = [_o(Slots.shellOverlay, 'dsh-pet', cell: 'pet')];
      final overlay = _seat(placement: SeatPlacement.overlay);
      expect(plan(Slots.shellOverlay, pet, seat: overlay).single.mode, SeatMode.webLink);
      final asked = plan(
        Slots.shellOverlay,
        pet,
        seat: overlay,
        overrides: const SeatOverrides({
          Slots.shellOverlay: {'dsh-pet': SeatOverride.island},
        }),
      );
      expect(asked.single.island?.form, IslandForm.overlay);
      expect(asked.single.island?.maskOfficial, isTrue);
    });
  });

  group('Tier A guesses', () {
    test('a guessed bundle page can be an island, a guessed list cell cannot', () {
      final guessed = plan(Slots.bundleConfig, [
        _o(Slots.bundleConfig, 'dsh-pet', cell: 'dsh-pet', inferred: true),
      ], inventory: _inventory(tier: ClientInventoryTier.boot));
      expect(guessed.single.island?.cell, 'dsh-pet');
      final section = plan(Slots.settingsSection, [_o(Slots.settingsSection, 'dsh-pet', cell: 'x', inferred: true)]);
      expect(section.single.mode, SeatMode.webLink);
    });
  });

  group('registry', () {
    test('registration order is priority; the same id replaces in place', () {
      final first = _FakeAdapter('a', {Slots.settingsSection}, packages: {'p'});
      final second = _FakeAdapter('b', {Slots.settingsSection}, packages: {'p'});
      final r = SlotAdapterRegistry([first, second]);
      final o = _o(Slots.settingsSection, 'p', cell: 'x');
      const info = PluginClientInfo(package: 'p');
      expect(r.adapterFor(o, info), same(first));
      final replacement = _FakeAdapter('a', {Slots.main}, packages: {'p'});
      r.register(replacement);
      expect(r.adapters.map((a) => a.id), ['a', 'b']);
      expect(r.adapterFor(o, info), same(second));
      expect(r.adapterFor(_o(Slots.main, 'p', cell: 'x'), info), same(replacement));
    });

    test('the standard batch, in §4.2 order', () {
      expect(SlotAdapterRegistry.standard().adapters.map((a) => a.id), [
        'schema-config',
        'cordis',
        'dsh-ui-panel',
        'pet',
      ]);
    });
  });
}
