// The seat vocabulary shared by the seat planner, the web islands and ui.json
// (docs/design/plugin-seams.md §4.1). Pure data, no providers.

import 'package:flutter/foundation.dart';

import '../../state/hosts_state.dart' show HostRef;
import 'slot_catalog.dart';

export 'slot_catalog.dart' show IslandForm;

/// One occupant: a package's cell in a slot.
@immutable
class SlotOccupant {
  const SlotOccupant({
    required this.slot,
    required this.package,
    this.cell = '',
    this.order = 0,
    this.label,
    this.official = false,
    this.inferred = false,
  });

  /// `settings.section`.
  final String slot;

  /// npm package name of the owner.
  final String package;

  /// The list id, the keyed key, or `''` for a single slot (and for an
  /// occupant whose cell is not known).
  final String cell;
  final int order;

  /// The registration's label in the app's language.
  final String? label;

  /// Ships with DSH (or is the app's own bridge): the planner skips it.
  final bool official;

  /// Guessed on a Tier A host from the package list (§5.1), not reported by
  /// the bridge: the island's ready gate is what confirms it.
  final bool inferred;

  @override
  bool operator ==(Object other) =>
      other is SlotOccupant &&
      other.slot == slot &&
      other.package == package &&
      other.cell == cell &&
      other.order == order &&
      other.label == label &&
      other.official == official &&
      other.inferred == inferred;

  @override
  int get hashCode => Object.hash(slot, package, cell, order, label, official, inferred);

  @override
  String toString() => 'SlotOccupant($slot, $package, cell: $cell${inferred ? ', inferred' : ''})';
}

/// Where a seat sits in the native UI.
enum SeatPlacement {
  /// A whole page or a tab.
  page,

  /// A fixed-height bottom panel.
  panel,

  /// A full-screen transparent layer above the native UI.
  overlay,

  /// A list row (it opens something; never hosts an island itself).
  row;

  /// The island form a seat here can hold, if any.
  IslandForm? get islandForm => switch (this) {
    page => IslandForm.page,
    panel => IslandForm.panel,
    overlay => IslandForm.overlay,
    row => null,
  };
}

/// Host, conversation and placement of one seat.
@immutable
class SeatContext {
  const SeatContext({required this.host, this.sessionId, required this.placement, this.webAvailable = true});

  final HostRef host;

  /// Set for session / session-maybe slots.
  final String? sessionId;
  final SeatPlacement placement;

  /// The host serves DSH Web to this connection (not over the relay): islands
  /// and "open in DSH Web" entries are possible.
  final bool webAvailable;

  @override
  bool operator ==(Object other) =>
      other is SeatContext &&
      other.host == host &&
      other.sessionId == sessionId &&
      other.placement == placement &&
      other.webAvailable == webAvailable;

  @override
  int get hashCode => Object.hash(host, sessionId, placement, webAvailable);
}

/// What the inventory knows about one package (§5): the read-only facts a
/// [NativeSlotAdapter.canRender] decides on.
@immutable
class PluginClientInfo {
  const PluginClientInfo({
    required this.package,
    this.hasClient = false,
    this.rev,
    this.official = false,
    this.enabled = false,
    this.installed = false,
    this.version,
    this.rowIds = const [],
    this.configNamespaces = const [],
    this.fallbackNamespaces = const [],
    this.panels = const [],
    this.pet,
  });

  /// A package the inventory has not listed (a dynamic Cordis plugin, or a
  /// client package of a multi-package bundle): it occupies a slot, so it has
  /// a browser half.
  const PluginClientInfo.assumed(this.package)
    : hasClient = true,
      rev = null,
      official = false,
      enabled = true,
      installed = false,
      version = null,
      rowIds = const [],
      configNamespaces = const [],
      fallbackNamespaces = const [],
      panels = const [],
      pet = null;

  final String package;

  /// The boot graph loads a browser half for it.
  final bool hasClient;

  /// Boot graph revision of that browser half.
  final String? rev;
  final bool official;
  final bool enabled;

  /// A bundle the profile declares (it has a page in the plugin manager).
  final bool installed;
  final String? version;

  /// Rows the bundle declares (`<package>#<row id>` keys `plugins.row.config`).
  final List<String> rowIds;

  /// Rows whose `settings/describe` namespace the app can draw as a form
  /// (`autoGenerate != false` and fields to show), in bundle order.
  final List<String> configNamespaces;

  /// Described settings namespaces without a native form, in bundle order.
  final List<String> fallbackNamespaces;

  /// Declarative panels the package registered with the bridge (§4.3).
  final List<String> panels;

  /// Pet protocol the package declares (`codex`, `linxin`), when known.
  final String? pet;
}

/// Everything a web island needs to open (§6). Items of one seat with equal
/// specs are one island: the panel island shows every planned occupant of the
/// seat's slot stacked, so its spec names no cell or package.
@immutable
class IslandSpec {
  const IslandSpec({
    required this.host,
    required this.form,
    required this.slot,
    this.cell,
    this.package,
    this.sessionId,
    this.maskOfficial = false,
  });

  final HostRef host;
  final IslandForm form;
  final String slot;

  /// The occupant to show (keyed key, list id); null shows the whole slot.
  final String? cell;

  /// Owner of [cell], for recipes and diagnostics.
  final String? package;
  final String? sessionId;

  /// A list slot: the bridge hides the official entries in island mode.
  final bool maskOfficial;

  /// Identity for reuse and failure bookkeeping.
  String get key => [
    host.kind.name,
    host.id,
    form.name,
    slot,
    package != null && package != cell ? '$package:${cell ?? ''}' : (cell ?? ''),
    sessionId ?? '',
  ].join('|');

  @override
  bool operator ==(Object other) =>
      other is IslandSpec &&
      other.host == host &&
      other.form == form &&
      other.slot == slot &&
      other.cell == cell &&
      other.package == package &&
      other.sessionId == sessionId &&
      other.maskOfficial == maskOfficial;

  @override
  int get hashCode => Object.hash(host, form, slot, cell, package, sessionId, maskOfficial);

  @override
  String toString() => 'IslandSpec($key)';
}

/// The island memory policy (§7), implemented by the islands runtime. The
/// planner only asks whether an island may be planned; it never creates one.
abstract interface class IslandBudget {
  /// Cheap and side-effect free: memory tier and live islands, renderer
  /// health, specs that failed their ready gate for this DSH release.
  bool canOpen(IslandSpec spec);
}

/// No islands at all (the default until the islands runtime is wired, and
/// what tests use for "web link only").
class NoIslandBudget implements IslandBudget {
  const NoIslandBudget();

  @override
  bool canOpen(IslandSpec spec) => false;
}

/// Every island allowed (tests).
class OpenIslandBudget implements IslandBudget {
  const OpenIslandBudget();

  @override
  bool canOpen(IslandSpec spec) => true;
}

/// What ui.json (`plugins.seats`, §10.2) asks for one package in one slot.
enum SeatOverride {
  native,
  island,
  web,
  hidden;

  /// The ui.json value (`native`, `island`, `web`, `hidden`), or null.
  static SeatOverride? tryParse(Object? value) => switch (value) {
    'native' => native,
    'island' => island,
    'web' => web,
    'hidden' => hidden,
    _ => null,
  };
}

/// `plugins.seats`: slot → package → override.
@immutable
class SeatOverrides {
  const SeatOverrides([this.bySlot = const {}]);

  static const none = SeatOverrides();

  final Map<String, Map<String, SeatOverride>> bySlot;

  SeatOverride? lookup(String slot, String package) => bySlot[slot]?[package];

  bool get isEmpty => bySlot.values.every((m) => m.isEmpty);

  @override
  bool operator ==(Object other) => other is SeatOverrides && mapEquals(_flat, other._flat);

  @override
  int get hashCode => Object.hashAllUnordered(_flat.entries.map((e) => Object.hash(e.key, e.value)));

  Map<String, SeatOverride> get _flat => {
    for (final MapEntry(key: slot, value: packages) in bySlot.entries)
      for (final MapEntry(key: package, value: value) in packages.entries) '$slot\u0000$package': value,
  };
}
