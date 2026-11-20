/// Which packages run a browser half, and where they sit in the official web
/// client's slots (docs/design/plugin-seams.md §5).
///
/// * Tier A, any Host: [PluginsApi.listBundles] plus the boot graph the Host
///   injects into its index page as `__DSH_BOOT__` ([parseWebBootGraph]; the
///   page is read as text, nothing in it runs).
/// * Tier B, a Host with the app's `dsh-go-bridge` package: its occupancy table
///   at `GET /dsh-go/v1/inventory` ([BridgeInventory]).
///
/// Both pages are HTTP routes, so over the relay tunnel only the bundle list
/// is left ([ClientInventoryTier.bundles]).
///
/// Boot graph shape verified against DSH 0.2.1-rc.2
/// (`dsh-client-modules/lib/types/client/manifest.d.ts` `WebBootGraph`;
/// `dsh-host-webserver` renders it as
/// `<script>globalThis["__DSH_BOOT__"] = {...}</script>` with `<` escaped).
library;

import 'carrier.dart';
import 'connection.dart';
import 'dsh_go_api.dart';
import 'errors.dart';
import 'json.dart';
import 'plugins_api.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Boot graph (Tier A)
// -----------------------------------------------------------------------------

/// The Host's release identity (`WebBootRelease`).
class WebBootRelease {
  const WebBootRelease({required this.version, this.commit});

  static WebBootRelease? fromJson(Object? json) {
    final map = asMap(json);
    final version = asString(map?['version']);
    if (map == null || version == null || version.isEmpty) return null;
    return WebBootRelease(version: version, commit: asString(map['commit']));
  }

  final String version;
  final String? commit;

  @override
  bool operator ==(Object other) => other is WebBootRelease && other.version == version && other.commit == commit;

  @override
  int get hashCode => Object.hash(version, commit);

  @override
  String toString() => commit == null ? version : '$version ($commit)';
}

/// One composed client entry (`WebBootEntry`): a package with a browser half.
class WebBootEntry {
  const WebBootEntry({
    required this.id,
    this.url = '',
    this.rev = '',
    this.inject = const [],
    this.external = const [],
    this.immediately = false,
  });

  /// Entry name, which is the package name.
  final String id;

  /// Document-relative combo script of this entry.
  final String url;

  /// Opaque artifact revision.
  final String rev;

  /// Package rows that must arrive first.
  final List<String> inject;
  final List<String> external;

  /// Stage-one prefetch.
  final bool immediately;
}

/// `window.__DSH_BOOT__` (`WebBootGraph`).
class WebBootGraph {
  const WebBootGraph({required this.rev, this.release, this.entries = const []});

  /// Lenient reader: needs an object with an `entries` array; entries without
  /// an id are skipped. Null for anything else.
  static WebBootGraph? fromJson(Object? json) {
    final map = asMap(json);
    final entries = asList(map?['entries']);
    if (map == null || entries == null) return null;
    final seen = <String>{};
    return WebBootGraph(
      rev: asString(map['rev']) ?? '',
      release: WebBootRelease.fromJson(map['release']),
      entries: [
        for (final raw in entries)
          if (asMap(raw) case final e?)
            if (asString(e['id']) case final id? when id.isNotEmpty && seen.add(id))
              WebBootEntry(
                id: id,
                url: asString(e['url']) ?? '',
                rev: asString(e['rev']) ?? '',
                inject: asStringList(e['inject']),
                external: asStringList(e['external']),
                immediately: e['immediately'] == true,
              ),
      ],
    );
  }

  /// Consistency anchor over the whole graph; changes with the plugin set.
  final String rev;
  final WebBootRelease? release;

  /// In module-graph order.
  final List<WebBootEntry> entries;

  /// Every package with a browser half.
  Set<String> get packages => {for (final e in entries) e.id};

  WebBootEntry? entry(String package) => entries.where((e) => e.id == package).firstOrNull;
}

/// Index pages larger than this are not searched (the 0.2.1-rc.2 page is a
/// few KiB; the graph itself grows with the plugin count).
const webBootMaxPageBytes = 4 << 20;

final _bootAssignment = RegExp(
  r'''(?:globalThis|window|self)\s*(?:\.\s*__DSH_BOOT__|\[\s*(["'])__DSH_BOOT__\1\s*\])\s*=\s*''',
);

/// The boot graph in the Host's index page, or null when the page has none
/// (or it does not parse). Reads text only: the object literal after the
/// `__DSH_BOOT__` assignment is decoded as JSON.
WebBootGraph? parseWebBootGraph(String html) {
  if (html.length > webBootMaxPageBytes) return null;
  for (final match in _bootAssignment.allMatches(html)) {
    final literal = _jsonObjectAt(html, match.end);
    if (literal == null) continue;
    final graph = WebBootGraph.fromJson(tryDecodeJson(literal));
    if (graph != null) return graph;
  }
  return null;
}

const _quote = 0x22, _backslash = 0x5C, _newline = 0x0A, _less = 0x3C;
const _openBrace = 0x7B, _closeBrace = 0x7D, _openBracket = 0x5B, _closeBracket = 0x5D;

/// The balanced `{...}` starting at [start] (JSON string rules), or null.
String? _jsonObjectAt(String text, int start) {
  if (start >= text.length || text.codeUnitAt(start) != _openBrace) return null;
  var depth = 0;
  var inString = false;
  for (var i = start; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (c == _backslash) {
        i++;
      } else if (c == _quote) {
        inString = false;
      } else if (c == _newline) {
        return null; // JSON strings never span lines.
      }
      continue;
    }
    switch (c) {
      case _quote:
        inString = true;
      case _openBrace || _openBracket:
        depth++;
      case _closeBrace || _closeBracket:
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      case _less:
        return null; // Rendered with `<` escaped: a raw one means the script ended.
    }
  }
  return null;
}

// -----------------------------------------------------------------------------
// Bridge occupancy (Tier B)
// -----------------------------------------------------------------------------

/// The app's bridge package; its own island-mode placeholders are not
/// occupants.
const dshGoBridgePackage = 'dsh-go-bridge';

/// Path of the bridge's inventory route.
const bridgeInventoryPath = '/dsh-go/v1/inventory';

/// A package's cell in a slot as the bridge reported it.
class ClientSlotOccupant {
  const ClientSlotOccupant({
    required this.slot,
    required this.package,
    this.cell = '',
    this.order = 0,
    this.label,
    this.official = false,
  });

  /// Null without a package name.
  static ClientSlotOccupant? fromJson(String slot, Object? json) {
    final map = asMap(json);
    final package = asString(map?['package']);
    if (map == null || package == null || package.isEmpty) return null;
    return ClientSlotOccupant(
      slot: slot,
      package: package,
      cell: asString(map['cell']) ?? '',
      order: asInt(map['order']) ?? 0,
      label: LocalizedText.fromJson(map['label']),
      official: map['official'] == true,
    );
  }

  final String slot;
  final String package;

  /// List id, keyed key, or `''` for a single slot.
  final String cell;
  final int order;
  final LocalizedText? label;

  /// As the bridge marked it; [ClientInventory] adds its own judgement.
  final bool official;

  ClientSlotOccupant copyWith({bool? official}) => ClientSlotOccupant(
    slot: slot,
    package: package,
    cell: cell,
    order: order,
    label: label,
    official: official ?? this.official,
  );
}

/// One `packages[]` row of the bridge inventory.
class BridgePackage {
  const BridgePackage({required this.name, this.hasClient = false, this.rev, this.panels = const [], this.pet});

  static BridgePackage? fromJson(Object? json) {
    final map = asMap(json);
    final name = asString(map?['name']);
    if (map == null || name == null || name.isEmpty) return null;
    return BridgePackage(
      name: name,
      hasClient: map['hasClient'] == true,
      rev: asString(map['rev']),
      panels: asStringList(map['panels']),
      pet: asString(map['pet']),
    );
  }

  final String name;
  final bool hasClient;
  final String? rev;

  /// Declarative panel ids.
  final List<String> panels;

  /// Pet protocol (`codex`, `linxin`), when the package declares one.
  final String? pet;
}

/// `GET /dsh-go/v1/inventory`.
class BridgeInventory {
  const BridgeInventory({
    this.version = 1,
    this.release,
    this.bootRev,
    this.packages = const [],
    this.slots,
    this.occupancyStale = false,
    this.routeGuard = false,
  });

  /// Lenient reader; null when [json] is not an object.
  static BridgeInventory? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final rawSlots = asMap(map['slots']);
    return BridgeInventory(
      version: asInt(map['v']) ?? 1,
      release: WebBootRelease.fromJson(map['release']),
      bootRev: asString(map['bootRev']),
      packages: [for (final p in asListOrEmpty(map['packages'])) ?BridgePackage.fromJson(p)],
      slots: rawSlots == null
          ? null
          : {
              for (final MapEntry(key: slot, value: list) in rawSlots.entries)
                if (slot.isNotEmpty)
                  slot: [
                    for (final o in asListOrEmpty(list))
                      if (ClientSlotOccupant.fromJson(slot, o) case final occupant?
                          when occupant.package != dshGoBridgePackage)
                        occupant,
                  ],
            },
      occupancyStale: asMap(map['occupancy'])?['stale'] == true,
      routeGuard: map['routeGuard'] == true,
    );
  }

  final int version;
  final WebBootRelease? release;

  /// `__DSH_BOOT__.rev` of the page that reported [slots].
  final String? bootRev;
  final List<BridgePackage> packages;

  /// Slot key → occupants in composition order; null until a page reported.
  final Map<String, List<ClientSlotOccupant>>? slots;

  /// The bridge reports that [slots] do not match its current boot graph.
  /// False when an older bridge does not report freshness; callers must still
  /// check whether the table and revision are present and match their page.
  final bool occupancyStale;

  /// The route guard (the runtime's route-guard patch, or the bridge's fallback
  /// wrapper) is active.
  final bool routeGuard;
}

// -----------------------------------------------------------------------------
// Combined inventory
// -----------------------------------------------------------------------------

/// How much the inventory knows.
enum ClientInventoryTier {
  /// The bundle list only (relay tunnel): no browser halves known.
  bundles,

  /// Tier A: bundles plus the boot graph.
  boot,

  /// Tier B: the bridge's occupancy table as well.
  bridge,
}

/// One package as the seats see it.
class ClientPackage {
  const ClientPackage({
    required this.name,
    this.hasClient = false,
    this.rev,
    this.official = false,
    this.enabled = false,
    this.installed = false,
    this.version,
    this.rowIds = const [],
    this.panels = const [],
    this.pet,
  });

  final String name;
  final bool hasClient;
  final String? rev;
  final bool official;
  final bool enabled;
  final bool installed;
  final String? version;

  /// The bundle's row ids (each one a settings namespace).
  final List<String> rowIds;
  final List<String> panels;
  final String? pet;
}

/// Packages, their browser halves and (Tier B) slot occupancy of one Host.
class ClientInventory {
  const ClientInventory({
    this.tier = ClientInventoryTier.bundles,
    this.release,
    this.bootRev,
    this.packages = const {},
    this.slots,
    this.occupancyStale = false,
    this.routeGuard = false,
  });

  /// Merges what was read; any part may be missing.
  factory ClientInventory.combine({
    List<PluginBundle> bundles = const [],
    WebBootGraph? boot,
    BridgeInventory? bridge,
  }) {
    final bridgePackages = {for (final p in bridge?.packages ?? const <BridgePackage>[]) p.name: p};
    final clients = boot?.packages;
    final packages = <String, ClientPackage>{};
    ClientPackage package(String name, {PluginBundle? bundle}) {
      final fromBridge = bridgePackages[name];
      final entry = boot?.entry(name);
      return ClientPackage(
        name: name,
        hasClient: clients?.contains(name) ?? fromBridge?.hasClient ?? false,
        rev: entry?.rev ?? fromBridge?.rev,
        official: (bundle?.official ?? false) || isOfficialPackageName(name),
        enabled: bundle?.enabled ?? (entry != null || (fromBridge?.hasClient ?? false)),
        installed: bundle?.installed ?? false,
        version: bundle?.version,
        rowIds: [
          for (final row in bundle?.rows ?? const <PluginBundleRow>[])
            if (row.rowId.isNotEmpty) row.rowId,
        ],
        panels: fromBridge?.panels ?? const [],
        pet: fromBridge?.pet,
      );
    }

    for (final bundle in bundles) {
      if (bundle.name.isNotEmpty) packages[bundle.name] = package(bundle.name, bundle: bundle);
    }
    // Client packages that are not bundles of their own (hand-written rows,
    // installation infrastructure).
    for (final name in [...?clients, ...bridgePackages.keys]) {
      packages.putIfAbsent(name, () => package(name));
    }

    bool official(String name) => packages[name]?.official ?? isOfficialPackageName(name);
    final slots = bridge?.slots?.map(
      (slot, list) =>
          MapEntry(slot, [for (final o in list) o.official ? o : o.copyWith(official: official(o.package))]),
    );
    return ClientInventory(
      tier: bridge != null
          ? ClientInventoryTier.bridge
          : boot != null
          ? ClientInventoryTier.boot
          : ClientInventoryTier.bundles,
      release: boot?.release ?? bridge?.release,
      bootRev: boot?.rev ?? bridge?.bootRev,
      packages: packages,
      slots: slots,
      occupancyStale:
          bridge != null &&
          (bridge.occupancyStale ||
              bridge.slots == null ||
              bridge.bootRev == null ||
              (boot != null && bridge.bootRev != boot.rev)),
      routeGuard: bridge?.routeGuard ?? false,
    );
  }

  final ClientInventoryTier tier;
  final WebBootRelease? release;

  /// The boot graph revision the Host serves now (the bridge's when the page
  /// could not be read).
  final String? bootRev;

  /// By package name: every bundle, then client packages that are no bundle.
  final Map<String, ClientPackage> packages;

  /// Tier B occupancy; null below Tier B or before a page reported.
  final Map<String, List<ClientSlotOccupant>>? slots;

  /// The bridge is there but its table is missing or belongs to another boot
  /// graph: open a probe island to refresh it.
  final bool occupancyStale;
  final bool routeGuard;

  /// Browser halves are known (Tier A or B).
  bool get clientsKnown => tier != ClientInventoryTier.bundles;

  bool isOfficial(String package) => packages[package]?.official ?? isOfficialPackageName(package);
}

/// Ships with DSH (the `@deepseek-ai` scope), or is the app's bridge.
bool isOfficialPackageName(String name) => name.startsWith('@deepseek-ai/') || name == dshGoBridgePackage;

// -----------------------------------------------------------------------------
// Calls
// -----------------------------------------------------------------------------

/// Reads the client inventory of a [DshClient]'s Host.
extension ClientInventoryApi on DshClient {
  /// The Host's pages are reachable over this carrier (HTTP, SSH tunnel; not
  /// the relay).
  bool get canReadWebBoot => carrier is DshHttpCarrier;

  /// `GET /` with the session cookie, parsed with [parseWebBootGraph]. Null
  /// when the page has no boot graph. Throws `client-inventory/unsupported`
  /// on a carrier without pages and `client-inventory/http-<status>` when the
  /// Host refuses.
  Future<WebBootGraph?> readWebBoot({Duration timeout = const Duration(seconds: 15)}) async {
    final response = await _get('/', timeout);
    if (response.statusCode != 200) throw _httpError('/', response.statusCode);
    return parseWebBootGraph(response.text);
  }

  /// Tier B: `GET /dsh-go/v1/inventory`. Null for an explicitly missing route
  /// or a legacy 404 without an advertised inventory capability. Resource
  /// errors keep their code under `client-inventory/`; only an ambiguous 404
  /// calls [DshGoApi.readDshGoBridgeCapabilities], whose errors propagate unchanged.
  /// Other failures throw like [readWebBoot], or [DshProtocolException] when
  /// the body is not an inventory. Successful reads need no negotiation.
  Future<BridgeInventory?> readBridgeInventory({Duration timeout = const Duration(seconds: 10)}) async {
    final response = await _get(bridgeInventoryPath, timeout);
    if (response.statusCode == 404) {
      final body = asMap(tryDecodeJson(response.text));
      final error = asMap(body?['error']) ?? body;
      final code = asString(error?['code']);
      if (code == 'route-not-found') return null;
      if (code != null) {
        throw DshRemoteException(
          'client-inventory/$code',
          asString(error?['message']) ?? '$bridgeInventoryPath: HTTP 404',
          {'path': bridgeInventoryPath, 'status': 404},
        );
      }
      final bridge = await readDshGoBridgeCapabilities(timeout: timeout);
      if (bridge == null || !bridge.capabilities.contains('inventory')) return null;
    }
    if (response.statusCode != 200) throw _httpError(bridgeInventoryPath, response.statusCode);
    final inventory = BridgeInventory.fromJson(tryDecodeJson(response.text));
    if (inventory == null) throw const DshProtocolException('$bridgeInventoryPath: not an inventory object');
    return inventory;
  }

  /// Bundles (required), then the boot graph and the bridge table where the
  /// carrier reaches them; a failure of either optional part only lowers the
  /// tier.
  Future<ClientInventory> readClientInventory() async {
    final boot = canReadWebBoot ? _orNull(readWebBoot()) : Future<WebBootGraph?>.value();
    final bridge = canReadWebBoot ? _orNull(readBridgeInventory()) : Future<BridgeInventory?>.value();
    final bundles = await listBundles();
    return ClientInventory.combine(bundles: bundles, boot: await boot, bridge: await bridge);
  }

  Future<DshHttpResponse> _get(String path, Duration timeout) {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw DshRemoteException('client-inventory/unsupported', 'This connection cannot read the Host pages', {
        'path': path,
      });
    }
    return carrier.connection.get(path, timeout: timeout);
  }
}

DshRemoteException _httpError(String path, int status) =>
    DshRemoteException('client-inventory/http-$status', '$path: HTTP $status', {'path': path, 'status': status});

Future<T?> _orNull<T>(Future<T?> future) => future.then<T?>((v) => v, onError: (Object _) => null);
