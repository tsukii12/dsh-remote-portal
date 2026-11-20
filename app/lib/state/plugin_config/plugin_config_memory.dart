// The complete plugin configuration interface (docs/design/plugin-config.md)
// held in memory: what the page and its tests run against until the Host
// serves it. It follows the proposal to the letter — complete schemas with
// `meta.volatile` on live nodes, secrets never read back, live writes without
// a reload, other writes stored then reloaded, and a failed reload undone —
// so swapping in the Host's implementation changes no caller.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../engine_settings_state.dart' show schemaAt;
import 'plugin_config_api.dart';

/// One entry the in-memory Host serves.
class MemoryPluginEntry {
  MemoryPluginEntry({
    required this.ns,
    required this.schema,
    Map<String, Object?>? base,
    Map<String, Object?>? user,
    this.revision = 0,
    this.autoGenerate = true,
    this.failed = false,
    this.error,
    this.overridden = false,
    this.owner,
    this.bundle,
  }) : base = base ?? {},
       user = user ?? {},
       node = SchemaNode.fromJson(schema);

  final String ns;

  /// `schema.toJSON()` (inline or `{uid, refs}`), live nodes marked.
  final Object? schema;
  final SchemaNode node;

  /// Beneath the profile, defaults resolved.
  Map<String, Object?> base;

  /// The profile's own values (secrets kept apart in [secrets]).
  Map<String, Object?> user;
  int revision;
  bool autoGenerate;
  bool failed;
  String? error;

  /// A host or command-line overlay sets its whole config: read as not
  /// writable, writes refused; listed so (`writable: false`, `reason:
  /// overridden`) only with an [owner], as bridge R7 lists it.
  bool overridden;

  /// Listed as bridge R7 lists it: who carries the entry (`optional`,
  /// `installed`) and the bundle. Null: listed as before R7.
  String? owner;
  String? bundle;

  /// Secret values by dotted path: written, never read back.
  final Map<String, Object?> secrets = {};

  List<List<String>> get secretPaths {
    final paths = <List<String>>[];
    void walk(SchemaNode source, List<String> path, int depth) {
      final node = source.effective;
      if (depth > 16) return;
      if (source.isSecret || node.isSecret) {
        paths.add(path);
        return;
      }
      for (final MapEntry(:key, :value) in (node.fields ?? const <String, SchemaNode>{}).entries) {
        walk(value, [...path, key], depth + 1);
      }
    }

    walk(node, const [], 0);
    return paths;
  }

  bool _isSecret(List<String> path) => secretPaths.any((p) => p.join('.') == path.join('.'));

  Map<String, Object?> _redact(Map<String, Object?> map) {
    var copy = map;
    for (final path in secretPaths) {
      copy = withoutPath(copy, path);
    }
    return copy;
  }

  Map<String, Object?> get value => _merge(base, user);

  SettingsNamespaceView view({bool writable = true}) => SettingsNamespaceView(
    ns: ns,
    schema: node,
    value: _redact(value),
    base: _redact(base),
    user: _redact(user),
    revision: revision,
    autoGenerate: autoGenerate,
    secrets: [for (final path in secretPaths) SettingsSecretSlot(path, set: secrets.containsKey(path.join('.')))],
    writable: writable,
  );
}

Map<String, Object?> _merge(Map<String, Object?> under, Map<String, Object?> over) {
  final merged = {...under};
  for (final MapEntry(:key, :value) in over.entries) {
    final below = merged[key];
    merged[key] = below is Map<String, Object?> && value is Map<String, Object?> ? _merge(below, value) : value;
  }
  return merged;
}

/// [PluginConfigApi] in memory.
class MemoryPluginConfigApi implements PluginConfigApi {
  MemoryPluginConfigApi(
    Iterable<MemoryPluginEntry> entries, {
    this.writable = true,
    this.step = Duration.zero,
    this.lazy = false,
  }) : entries = {for (final e in entries) e.ns: e};

  final Map<String, MemoryPluginEntry> entries;
  bool writable;

  /// Serve forms one entry at a time, as the dsh-go bridge does.
  final bool lazy;

  /// Listed, not editable: entryId → (state, reason).
  final Map<String, (String, String)> unavailable = {};

  /// How long each step of a reload takes.
  Duration step;

  /// Holds a reloading apply until completed (progress tests).
  Completer<void>? gate;

  /// The next reload fails; [undoFails] also keeps the new values (the Host
  /// could not put the old ones back).
  String? failNextReload;
  bool undoFails = false;

  /// The next apply is refused with this message (nothing written).
  String? rejectNext;

  /// Reference → value.
  final Map<String, String> credentials = {};

  /// Calls in order (method, ns), for tests.
  final List<(String, String?)> calls = [];

  final _changes = StreamController<void>.broadcast();

  /// Another device changed [path] of [ns].
  void externalSet(String ns, List<String> path, Object? value) {
    final entry = entries[ns]!;
    entry.user = withPath(entry.user, path, value);
    entry.revision++;
    _changes.add(null);
  }

  bool _live(MemoryPluginEntry entry, List<String> path) =>
      PluginConfigForm(entry.view()).isLive(path);

  PluginConfigForm _form(MemoryPluginEntry e) => PluginConfigForm(
    e.view(writable: writable && !e.overridden),
    failed: e.failed,
    error: e.error,
  );

  @override
  Future<PluginConfigCatalog> describe() async {
    calls.add(('describe', null));
    return PluginConfigCatalog(
      writable: writable,
      complete: true,
      lazy: lazy,
      forms: lazy ? const {} : {for (final e in entries.values) e.ns: _form(e)},
      entries: {
        for (final e in entries.values)
          e.ns: e.owner != null
              ? PluginConfigEntry(
                  e.ns,
                  owner: e.owner,
                  bundle: e.bundle,
                  kind: 'plugin',
                  writable: !e.overridden,
                  reason: e.overridden ? 'overridden' : null,
                )
              : PluginConfigEntry(e.ns),
        for (final MapEntry(:key, value: (state, reason)) in unavailable.entries)
          key: PluginConfigEntry(key, state: state, configurable: false, reason: reason),
      },
    );
  }

  @override
  Future<PluginConfigForm?> read(String ns) async {
    calls.add(('read', ns));
    return switch (entries[ns]) {
      final e? => _form(e),
      null => null,
    };
  }

  @override
  Stream<PluginConfigEvent> apply(String ns, List<SettingsOp> ops, {Object? revision}) async* {
    calls.add(('apply', ns));
    final entry = entries[ns];
    if (entry == null) {
      throw const PluginConfigFailure(PluginConfigFailureKind.rejected, 'No configurable plugin entry');
    }
    yield const PluginConfigProgress(PluginConfigStep.saving);
    await _wait();
    if (!writable || entry.overridden) throw const PluginConfigFailure(PluginConfigFailureKind.rejected, 'read-only');
    if (revision != null && revision != entry.revision) {
      throw const PluginConfigFailure(PluginConfigFailureKind.conflict, 'changed since it was read');
    }
    if (rejectNext case final message?) {
      rejectNext = null;
      throw PluginConfigFailure(PluginConfigFailureKind.rejected, message);
    }
    final before = (user: entry.user, secrets: {...entry.secrets});
    var user = entry.user;
    for (final op in ops) {
      if (entry._isSecret(op.path)) {
        if (op.op == 'set') {
          entry.secrets[op.path.join('.')] = op.value;
        } else {
          entry.secrets.remove(op.path.join('.'));
        }
        continue;
      }
      if (op.op == 'set') {
        final node = schemaAt(entry.node, op.path);
        if (node == null) {
          throw PluginConfigFailure(PluginConfigFailureKind.rejected, 'unknown field ${op.path.join('.')}');
        }
        user = withPath(user, op.path, op.value);
      } else {
        user = withoutPath(user, op.path);
      }
    }
    final reload = ops.any((op) => !_live(entry, op.path));
    entry.user = user;
    entry.revision++;
    if (!reload) {
      _changes.add(null);
      yield PluginConfigApplied(_form(entry));
      return;
    }
    yield const PluginConfigProgress(PluginConfigStep.reloading);
    await _wait();
    if (failNextReload case final message?) {
      failNextReload = null;
      if (undoFails) {
        entry.failed = true;
        entry.error = message;
      } else {
        entry.user = before.user;
        entry.secrets
          ..clear()
          ..addAll(before.secrets);
        entry.revision++;
      }
      _changes.add(null);
      throw PluginConfigFailure(PluginConfigFailureKind.reloadFailed, message, rolledBack: !undoFails);
    }
    entry.failed = false;
    entry.error = null;
    _changes.add(null);
    yield PluginConfigApplied(_form(entry), reloaded: true);
  }

  Future<void> _wait() async {
    if (gate case final gate?) await gate.future;
    if (step > Duration.zero) await Future<void>.delayed(step);
  }

  @override
  Future<Map<String, CredentialStatus>> describeCredentials(Set<String> refs) async => {
    for (final ref in refs) ref: CredentialStatus(configured: credentials.containsKey(ref), writable: true),
  };

  @override
  Future<void> setCredential(String ref, String value) async {
    credentials[ref] = value;
    _changes.add(null);
  }

  @override
  Future<void> clearCredential(String ref) async {
    credentials.remove(ref);
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
}
