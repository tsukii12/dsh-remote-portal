// What the native plugin configuration page reads and writes through
// (docs/design/plugin-config.md): the profile's plugin entries, each entry's
// complete Config form, one write that applies live fields at once and
// reloads the plugin for the rest, and the credential store for secrets bound
// to a reference.
//
// Two Hosts implement it: the dsh-go bridge's `/dsh-go/v1/plugin-config`
// routes (BridgePluginConfigApi, PLUGIN-CONFIG-CONTRACT R1), and where those
// are missing DSH 0.2.1's own `settings/describe` + `settings/mutate`, which
// serve `.volatile()` fields only (EngineSettingsPluginConfigApi).
// MemoryPluginConfigApi holds the complete interface in memory for tests.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../engine_settings_state.dart' show credentialRefsOf, describeSettingsError, schemaAt;

/// One plugin entry's form: the schema, the layers and which fields are live.
@immutable
class PluginConfigForm {
  const PluginConfigForm(
    this.view, {
    this.allLive = false,
    this.failed = false,
    this.error,
    this._revision,
    this.secretBindings = const {},
  });

  /// Schema, resolved value, layers and secret slots (secrets redacted).
  final SettingsNamespaceView view;

  /// Every field takes effect without a reload (what `settings/describe`
  /// serves). Otherwise a field is live when it or an ancestor carries
  /// `meta.volatile`.
  final bool allLive;

  /// The plugin did not start (a bad value can still be fixed here).
  final bool failed;
  final String? error;

  final Object? _revision;

  /// What a write is checked against: the Host's token as read (opaque),
  /// else the namespace revision.
  Object get revision => _revision ?? view.revision;

  /// Secret positions the Host described, by [FieldRef] key: the credential
  /// each is bound to, or null for one that cannot be written here.
  final Map<String, String?> secretBindings;

  String get ns => view.ns;

  /// The credentials this form declares: bound secrets, and secrets read
  /// from a `credential-ref` field.
  Set<String> get credentialRefs => {
    ...credentialRefsOf({ns: view}),
    ...secretBindings.values.nonNulls,
  };

  /// The plugin opted out of a generated page (`configure({ auto: false })`).
  bool get prefersOwnPage => !view.autoGenerate;

  /// Changing [path] takes effect at once (no reload).
  bool isLive(List<String> path) {
    if (allLive) return true;
    if (view.schema.meta.volatile || view.schema.effective.meta.volatile) return true;
    for (var length = 1; length <= path.length; length++) {
      final node = schemaAt(view.schema, path.sublist(0, length));
      if (node == null) return false;
      if (node.meta.volatile || node.effective.meta.volatile) return true;
    }
    return false;
  }

  /// Some field reloads the plugin when it changes.
  bool get hasReloadFields {
    if (allLive) return false;
    final fields = view.schema.fields;
    if (fields == null) return !isLive(const []);
    return fields.keys.any((key) => !isLive([key]));
  }

  PluginConfigForm withView(SettingsNamespaceView next) => PluginConfigForm(
    next,
    allLive: allLive,
    failed: failed,
    error: error,
    revision: _revision,
    secretBindings: secretBindings,
  );
}

/// One entry of the profile as the Host lists it.
@immutable
class PluginConfigEntry {
  const PluginConfigEntry(
    this.entryId, {
    this.package,
    this.label,
    this.state = 'active',
    this.configurable = true,
    this.reason,
    this.owner,
    this.bundle,
    this.kind,
    this.source,
    this.writable,
  });

  /// The bridge's list item ([PluginConfigEntrySummary]).
  factory PluginConfigEntry.listed(PluginConfigEntrySummary e) => PluginConfigEntry(
    e.entryId,
    package: e.package,
    label: e.label,
    state: e.state,
    configurable: e.configurable,
    reason: e.reason,
    owner: e.owner,
    bundle: e.bundle,
    kind: e.kind,
    source: e.source,
    writable: e.writable,
  );

  /// The profile id, also the settings namespace and the only write target.
  final String entryId;
  final String? package;

  /// Bridge R7: the declaring bundle's title (every entry of a bundle shares
  /// it); older: the entry id.
  final LocalizedText? label;

  /// `active`, `inactive`, `failed`, `unsupported`.
  final String state;

  /// Its complete Config can be read here.
  final bool configurable;

  /// Why not (`no-schema`, `not-active`, `ambiguous-id`, `nested-include`,
  /// `unsupported-schema`, R7 `entry-unavailable`); why a configurable
  /// entry is not [writable] (R7 `overridden`, `host-unavailable`).
  final String? reason;

  /// Bridge R7, null before: `core`, `optional`, `installed`, `overlay`
  /// ([PluginConfigEntrySummary.owner]).
  final String? owner;

  /// Bridge R7: the enabled bundle that declares it (null: none proven).
  final String? bundle;

  /// Bridge R7: `plugin`, `core`, `overlay`.
  final String? kind;

  /// Bridge R7: `official-optional-bundle`, `installed-bundle`, `unverified`.
  final String? source;

  /// Bridge R7: a write would be taken. Null where the Host does not say
  /// in its list (an older bridge, DSH's own `settings/describe`).
  final bool? writable;

  /// Can be read here but not changed: the Host's list says so up front
  /// (R7), before the form is read.
  bool get readOnly => configurable && writable == false;

  /// [readOnly] because a host or command-line overlay sets its whole
  /// config (「由配置文件固定」).
  bool get fixedByFile => readOnly && (reason == null || reason == 'overridden');
}

/// Every configurable entry of the active Host.
@immutable
class PluginConfigCatalog {
  PluginConfigCatalog({
    required this.forms,
    Map<String, PluginConfigEntry>? entries,
    this.writable = true,
    this.complete = false,
    this.lazy = false,
  }) : entries = entries ?? {for (final ns in forms.keys) ns: PluginConfigEntry(ns)};

  /// Forms already read, by namespace (the entry's profile id).
  final Map<String, PluginConfigForm> forms;

  /// Every entry the Host lists, in its order.
  final Map<String, PluginConfigEntry> entries;

  /// Forms are read one entry at a time ([PluginConfigApi.read]).
  final bool lazy;

  /// The profile accepts writes.
  final bool writable;

  /// The Host serves fields that need a reload too, not only live ones.
  final bool complete;
}

/// Where a save stands while the Host applies it.
enum PluginConfigStep {
  /// Validating and storing the values.
  saving,

  /// The plugin restarts with them.
  reloading,
}

/// What [PluginConfigApi.apply] reports.
@immutable
sealed class PluginConfigEvent {
  const PluginConfigEvent();
}

final class PluginConfigProgress extends PluginConfigEvent {
  const PluginConfigProgress(this.step);
  final PluginConfigStep step;
}

/// The values took effect; [form] is the entry as the Host now has it.
final class PluginConfigApplied extends PluginConfigEvent {
  const PluginConfigApplied(this.form, {this.reloaded = false});
  final PluginConfigForm form;
  final bool reloaded;
}

enum PluginConfigFailureKind {
  /// Refused before anything was written (a value, a read-only profile, a
  /// home patch).
  rejected,

  /// Someone changed the plugin's settings since they were read.
  conflict,

  /// Stored, but the plugin did not come back up with them.
  reloadFailed,

  /// The entry is gone (stopped, replaced, removed).
  gone,

  /// The engine said it could not be reached; nothing was written.
  unreachable,

  /// The connection dropped mid-write: it may or may not have landed.
  unknown,
}

/// A failed apply, already in words.
class PluginConfigFailure implements Exception {
  const PluginConfigFailure(this.kind, this.message, {this.rolledBack = true, this.path});

  final PluginConfigFailureKind kind;
  final String message;

  /// The field the Host refused, when it named one.
  final List<String>? path;

  /// The Host put the previous values back (always true when nothing was
  /// written). False only after a failed reload it could not undo.
  final bool rolledBack;

  /// Nothing to undo: what was there before is what the plugin runs with.
  bool get settled => kind != PluginConfigFailureKind.reloadFailed || rolledBack;

  @override
  String toString() => message;
}

/// The Host side of the native plugin configuration.
abstract interface class PluginConfigApi {
  /// Every entry, with the forms already at hand; null while not connected.
  Future<PluginConfigCatalog?> describe();

  /// One entry's form; null when the Host no longer has it.
  Future<PluginConfigForm?> read(String ns);

  /// Applies [ops] to [ns] together, against [revision] as read. Fields under
  /// a live node take effect at once; any other field stores the values and
  /// reloads the plugin, and a failed reload puts the previous values back.
  /// Emits [PluginConfigProgress] steps, then one [PluginConfigApplied]; fails
  /// with a [PluginConfigFailure].
  Stream<PluginConfigEvent> apply(String ns, List<SettingsOp> ops, {Object? revision});

  Future<Map<String, CredentialStatus>> describeCredentials(Set<String> refs);
  Future<void> setCredential(String ref, String value);
  Future<void> clearCredential(String ref);

  /// Settings or credentials changed on the Host (another device, a reload
  /// that finished).
  Stream<void> get changes;
}

/// A settings, bridge or credentials call's failure as a
/// [PluginConfigFailure], in words (never the Host's own message: it can
/// carry the input).
PluginConfigFailure pluginConfigFailureOf(Object error) {
  if (error is PluginConfigFailure) return error;
  if (error is DshRemoteException && error.code.startsWith('plugin-config/')) {
    final path = switch (error.details['path']) {
      final List<Object?> p when p.isNotEmpty => [for (final s in p) '$s'],
      _ => null,
    };
    PluginConfigFailure failure(PluginConfigFailureKind kind, String message, {bool rolledBack = true}) =>
        PluginConfigFailure(kind, message, rolledBack: rolledBack, path: path);
    return switch (error.code.substring('plugin-config/'.length)) {
      'invalid-operation' => failure(PluginConfigFailureKind.rejected, appL10n.pluginConfigInvalidOperation),
      'entry-unavailable' => failure(PluginConfigFailureKind.gone, appL10n.pluginConfigGone),
      'conflict' => failure(PluginConfigFailureKind.conflict, appL10n.stateSettingsRefreshed),
      'overridden' => failure(PluginConfigFailureKind.rejected, appL10n.stateSettingsFromFile),
      'apply-failed' => failure(PluginConfigFailureKind.reloadFailed, appL10n.pluginConfigRestored),
      'invalid-config' => failure(PluginConfigFailureKind.rejected, appL10n.stateSettingsInvalidValue),
      'host-unavailable' => failure(PluginConfigFailureKind.unreachable, appL10n.commonEngineUnreachable),
      'recovery-failed' => failure(PluginConfigFailureKind.reloadFailed, appL10n.pluginConfigStopped, rolledBack: false),
      _ => failure(PluginConfigFailureKind.rejected, appL10n.stateSettingsRejected),
    };
  }
  if (error is DshTransportException || error is TimeoutException) {
    return PluginConfigFailure(PluginConfigFailureKind.unknown, appL10n.pluginConfigUnknown);
  }
  final message = describeSettingsError(error);
  if (error is DshRemoteException) {
    if (error.code == 'settings/conflict') return PluginConfigFailure(PluginConfigFailureKind.conflict, message);
    if (error.code == 'settings/apply-failed') {
      return PluginConfigFailure(
        PluginConfigFailureKind.reloadFailed,
        message,
        rolledBack: error.details['rolledBack'] != false,
      );
    }
    return PluginConfigFailure(PluginConfigFailureKind.rejected, message);
  }
  return PluginConfigFailure(PluginConfigFailureKind.unreachable, message);
}
