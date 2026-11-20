// Which profile entries are plugins the person may configure here
// (docs/design/plugin-config.md §7). An allowlist, denied by default: the
// plugin settings page lists, reads and writes an entry only when both of
// these say it is a plugin's, and either one refusing is a refusal —
//
//   * the plugin manager (`pluginManager/listBundles`), in the list the Host
//     confirmed last: a bundle the person chose carries it
//     ([PluginConfigScope.owns]; per bundle `official`, `optional`,
//     `installed`, `source`, `enabled`, `error`, and the `rows` its patch
//     inserts: `rowId` = the entry id, `moduleName`);
//   * the Host's list (`GET /dsh-go/v1/plugin-config`), where it says so:
//     the entry's `package` is the one the row loads, and from bridge R7
//     (runtime r14) its `owner` is `optional` or `installed`, its `kind`
//     `plugin` and its `bundle` the one carrying the row.
//
// Everything else — DSH's own core and runtime rows, the rows the App mounts
// for itself (the bridge, sign-in, phone control), anything unrecognised —
// is neither listed nor read nor written.
//
// Only the list the Host confirmed last counts (CR-a17797b): one kept on
// screen after a failed refresh, one being read again, an optimistic switch
// not yet answered, or one from another connection makes nothing a plugin
// ([PluginScopeStatus]).
//
// What a list item carries. Up to R6: `entryId`, `package`, `label` (= the
// id), `state`, `configurable`, `reason` — nothing that tells core from
// plugin (`package` cannot: the core, the official optional bundles and the
// App's phone-control row all load `@deepseek-ai/*` modules, and a row
// loaded by path has none), hence the bundles. R7 adds, decided by the Host
// from the same `listBundles`, for every entry it lists:
//
//   owner     core | optional | installed | overlay — overlay: no single
//             enabled bundle is proven to declare it (home and command-line
//             patches, the App's `--patch` rows)
//   bundle    that bundle's name; null when unproven
//   kind      plugin | core | overlay
//   source    official-optional-bundle | installed-bundle | unverified
//   writable  false on whatever is not configurable, and on a configurable
//             entry a host or command-line overlay covers (`reason`
//             `overridden`; `host-unavailable` when the engine cannot take
//             the write): readable, not writable (PluginConfigEntry.readOnly)
//   label     the declaring bundle's top-level `meta.title` (a string or
//             `{en, zh}`), else the id — every entry of a bundle shares it
//
// and refuses itself (403 `entry-unavailable`) what is not a plugin's. Its
// word only narrows the App's: `owner` core or overlay, an `owner` or `kind`
// the App does not know, another `bundle` — refused. A list without these
// fields (an older bridge) is scoped exactly as before. Measured on real r13
// and r14 Hosts (app/test/plugin_config/fixtures/).

import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import 'plugin_config_api.dart' show PluginConfigEntry, PluginConfigFailure, PluginConfigFailureKind;

/// What the plugin list a scope comes from can be trusted for.
enum PluginScopeStatus {
  /// The Host's latest successful answer on this connection, confirmed.
  confirmed,

  /// Not read yet, being read again, or an optimistic switch not answered.
  pending,

  /// The last read failed (an older list may still be on screen).
  failed,

  /// No plugin manager to ask: not connected.
  offline,
}

/// A row in scope: the package its module comes from (null for a path) and
/// the bundle that carries it.
typedef PluginConfigRow = ({String? package, String bundle});

/// The entries whose configuration belongs to a plugin the person chose.
@immutable
class PluginConfigScope {
  const PluginConfigScope._(this._rows, this.status);

  /// Nothing is a plugin until the plugin list is confirmed.
  static const none = PluginConfigScope._({}, PluginScopeStatus.pending);

  /// Nothing is a plugin: the plugin list could not be read.
  static const failed = PluginConfigScope._({}, PluginScopeStatus.failed);

  /// Nothing is a plugin: no plugin manager to ask.
  static const offline = PluginConfigScope._({}, PluginScopeStatus.offline);

  /// The rows of every bundle that [owns] its configuration, by row id, from
  /// a list the Host confirmed ([none] without one).
  factory PluginConfigScope.of(Iterable<PluginBundle>? bundles) {
    if (bundles == null) return none;
    // Every switched-on declaration counts, core layers included: an id
    // declared twice is not one bundle's alone (and the Host cannot address
    // it either, `ambiguous-id`), so it is nobody's here.
    final declared = <String, int>{};
    for (final bundle in bundles) {
      if (!bundle.enabled) continue;
      for (final row in bundle.rows) {
        declared[row.rowId] = (declared[row.rowId] ?? 0) + 1;
      }
    }
    final rows = <String, PluginConfigRow>{};
    for (final bundle in bundles) {
      if (!owns(bundle)) continue;
      for (final row in bundle.rows) {
        if (row.rowId.isEmpty || declared[row.rowId] != 1) continue;
        rows[row.rowId] = (package: modulePackage(row.moduleName), bundle: bundle.name);
      }
    }
    return PluginConfigScope._(Map.unmodifiable(rows), PluginScopeStatus.confirmed);
  }

  /// A bundle the person chose and whose rows are theirs to configure:
  /// switched on, loaded without a problem, and either an official optional
  /// bundle (shipped for the person to switch on: the voice-input kit, ...)
  /// or a package the profile installed itself (market, local path, an
  /// official on-demand one), which is what `source` marks.
  ///
  /// Not: the installation's own layers (`dsh-base`, `dsh-web-app`, ...:
  /// neither optional nor installed), alternatives not selected
  /// (`dsh-sdk-minimal` repeats core row ids), rows only patched by a bundle
  /// (`overrides`), rows the App inserts with `--patch` (in no bundle).
  static bool owns(PluginBundle bundle) =>
      bundle.enabled &&
      bundle.error == null &&
      ((bundle.official && bundle.optional) || (bundle.installed && bundle.source != null));

  /// The R7 owners whose entries can be a plugin's. `core` and `overlay`
  /// never are; neither is an owner the App does not know.
  static const pluginOwners = {'optional', 'installed'};

  /// What the Host says of an entry (bridge R7) leaves it a plugin's: no
  /// [owner] or [kind] at all (an older bridge), or a plugin's.
  static bool hostAllows({String? owner, String? kind}) =>
      (owner == null || pluginOwners.contains(owner)) && (kind == null || kind == 'plugin');

  final Map<String, PluginConfigRow> _rows;

  /// Whether the list behind it can be trusted ([allows] only when confirmed).
  final PluginScopeStatus status;

  bool get confirmed => status == PluginScopeStatus.confirmed;

  bool get isEmpty => _rows.isEmpty;

  /// Every entry id in scope.
  Iterable<String> get entryIds => _rows.keys;

  /// The bundle carrying [entryId], when it is in scope.
  String? bundleOf(String entryId) => _rows[entryId]?.bundle;

  /// [entryId] is a plugin's entry, by a confirmed list. What the Host says
  /// of it narrows this: a [package] it names must be the one the bundle's
  /// row loads (an id alone does not make a core entry a plugin), a [bundle]
  /// it names the one carrying the row, and its [owner] and [kind] must be a
  /// plugin's ([hostAllows]).
  bool allows(String entryId, {String? package, String? bundle, String? owner, String? kind}) {
    final row = _rows[entryId];
    if (!confirmed || row == null) return false;
    if (package != null && row.package != package) return false;
    if (bundle != null && row.bundle != bundle) return false;
    return hostAllows(owner: owner, kind: kind);
  }

  /// [allows], with what the Host [listed] for [entryId] (null: not listed).
  bool admits(String entryId, PluginConfigEntry? listed) => allows(
    entryId,
    package: listed?.package,
    bundle: listed?.bundle,
    owner: listed?.owner,
    kind: listed?.kind,
  );

  /// Why a read or write out of scope did not go out, in words.
  PluginConfigFailure refusal() => switch (status) {
    PluginScopeStatus.confirmed => PluginConfigFailure(
      PluginConfigFailureKind.rejected,
      appL10n.pluginConfigUnsupported,
    ),
    PluginScopeStatus.pending => PluginConfigFailure(
      PluginConfigFailureKind.rejected,
      appL10n.pluginConfigListUpdating,
    ),
    PluginScopeStatus.failed => PluginConfigFailure(PluginConfigFailureKind.rejected, appL10n.pluginConfigListFailed),
    PluginScopeStatus.offline => PluginConfigFailure(
      PluginConfigFailureKind.unreachable,
      appL10n.commonEngineUnreachable,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is PluginConfigScope && other.status == status && mapEquals(other._rows, _rows);

  @override
  int get hashCode =>
      Object.hash(status, Object.hashAllUnordered(_rows.entries.map((e) => Object.hash(e.key, e.value))));
}

/// The package a module specifier loads, as the bridge reports it:
/// `@scope/name/sub` → `@scope/name`, `name/sub` → `name`; a path, a
/// `file:` URL or a `cordis:` row → null.
String? modulePackage(String specifier) {
  if (specifier.isEmpty || RegExp(r'^(\.|/|file:|cordis:|[A-Za-z]:)').hasMatch(specifier)) return null;
  final parts = specifier.split('/');
  return parts.take(specifier.startsWith('@') ? 2 : 1).join('/');
}
