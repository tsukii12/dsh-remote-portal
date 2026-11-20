// Engine settings (`settings/describe`, `settings/mutate`, `credentials/*`)
// and the plugin inventory (`pluginInventory/list`) of the active host: the
// state behind the native 引擎设置 pages (lib/ui/engine_settings/).
//
// The engine owns the values. Every namespace is one Loader entry with a
// schemastery schema and three layers (`base` beneath the profile, the
// profile's own `user` layer, the resolved `value`); a home patch or a
// command-line overlay sits above them and makes the whole entry read-only.
// Writes are optimistic and per namespace in order, each sent with the
// revision the previous one returned; a stale revision is re-read and retried
// once when nobody else touched the same field.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';
import 'engine_error_text.dart';
import 'media_catalog.dart' show mediaKeyRefsOf;
import 'plugins_state.dart';

export 'package:dsh_client/dsh_client.dart'
    show
        CredentialStatus,
        PluginInventory,
        PluginInventoryEntry,
        PresetPluginRow,
        PresetPlugins,
        SchemaMeta,
        SchemaNode,
        SettingsNamespaceView,
        SettingsOp,
        jsonEquals,
        lookupPath;

// ── Model ────────────────────────────────────────────────────────────────────

/// One field of one namespace.
@immutable
class FieldRef {
  const FieldRef(this.ns, this.path);

  final String ns;
  final List<String> path;

  String get key => '$ns\u0000${path.join('\u0000')}';

  FieldRef child(String name) => FieldRef(ns, [...path, name]);

  @override
  bool operator ==(Object other) => other is FieldRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$ns:${path.join('.')}';
}

/// Where a field's value comes from.
enum FieldLayer {
  /// The deployment's value: schema default or the composition beneath the
  /// profile.
  inherited,

  /// Set by the user (the profile's own layer); can go back to [inherited].
  user,

  /// A home patch or command-line overlay decides it: read-only here.
  locked,
}

/// What a value at [node] is once it is there: the one member of an optional
/// value (`union([X, const(undefined)])`, schemastery's "X or nothing", as
/// `fallback: union([object({provider, model}), const(undefined)])` in
/// @nanmicoder/dsh-agent-teams 0.1.27), else [node] with wrappers resolved.
/// A single constant stays a union: "this value or nothing" is a choice.
SchemaNode schemaValueOf(SchemaNode node) {
  final n = node.effective;
  if (!n.nullable) return n;
  final members = n.members;
  return members.length == 1 && members.single.type != 'const' ? members.single : n;
}

/// The schema node at [path] under [root] (object fields, array items by
/// index, dict values by key); null when the schema has no such field.
Map<String, SchemaNode>? schemaObjectFields(SchemaNode root, [Set<SchemaNode>? ancestors]) {
  final node = schemaValueOf(root);
  final seen = ancestors ?? <SchemaNode>{};
  if (seen.contains(node)) return null;
  if (node.type == 'object') return node.dict;
  if (node.type != 'intersect') return null;
  final next = {...seen, node};
  final fields = <String, SchemaNode>{};
  for (final member in node.list) {
    final child = schemaObjectFields(member, next);
    if (child != null) fields.addAll(child);
  }
  return fields;
}

SchemaNode? schemaAt(SchemaNode root, List<String> path) {
  SchemaNode? node = root;
  for (final key in path) {
    final current = node == null ? null : schemaValueOf(node);
    if (current == null) return null;
    final fields = schemaObjectFields(current);
    if (fields != null) {
      node = fields[key];
    } else if (current.type == 'array' || current.type == 'dict') {
      node = current.inner;
    } else if (current.type == 'tuple') {
      final index = int.tryParse(key);
      node = index != null && index >= 0 && index < current.list.length ? current.list[index] : null;
    } else {
      return null;
    }
  }
  return node;
}

/// A disabled object locks its descendants as well as its own row.
bool schemaPathDisabled(SchemaNode root, List<String> path) {
  bool? walk(SchemaNode source, List<String> remaining, bool inherited, Set<SchemaNode> ancestors) {
    final node = schemaValueOf(source);
    if (ancestors.contains(node)) return null;
    final disabled = inherited || source.meta.disabled || source.effective.meta.disabled || node.meta.disabled;
    if (remaining.isEmpty) return disabled;
    final next = {...ancestors, node};
    if (node.type == 'intersect') {
      // Match schemaAt's last-member precedence, without flattening away the
      // metadata of the object member that owns this particular field.
      for (final member in node.list.reversed) {
        final result = walk(member, remaining, disabled, next);
        if (result != null) return result;
      }
      return null;
    }
    final key = remaining.first;
    SchemaNode? child;
    if (node.type == 'object') {
      child = node.dict[key];
    } else if (node.type == 'array' || node.type == 'dict') {
      child = node.inner;
    } else if (node.type == 'tuple') {
      final index = int.tryParse(key);
      if (index != null && index >= 0 && index < node.list.length) child = node.list[index];
    }
    return child == null ? null : walk(child, remaining.sublist(1), disabled, next);
  }

  return walk(root, path, false, <SchemaNode>{}) ?? false;
}

/// [EngineSettings.isLocked] by snapshot (snapshots never change).
final _lockedOf = Expando<Map<String, bool>>('EngineSettings.isLocked');

/// The active engine's settings as the pages read them: the namespaces (with
/// optimistic edits applied), credential states and what is saving or failed.
@immutable
class EngineSettings {
  const EngineSettings({
    required this.namespaces,
    this.writable = true,
    this.credentials = const {},
    this.saving = const {},
    this.errors = const {},
    this.locked = const {},
    this.staged = const {},
    this.secretBindings = const {},
    this.local = true,
    this._hostLabel,
    this._origin,
  });

  final Map<String, SettingsNamespaceView> namespaces;

  /// The profile accepts writes.
  final bool writable;

  /// `credentials/describe` by reference, for secret fields that name one.
  final Map<String, CredentialStatus> credentials;

  /// [FieldRef.key]s with a write in flight.
  final Set<String> saving;

  /// Last failure by [FieldRef.key], in words.
  final Map<String, String> errors;

  /// Namespaces a write found overridden by a home patch.
  final Set<String> locked;

  /// [FieldRef.key]s edited but not saved yet (a plugin form's fields that
  /// take effect on a reload).
  final Set<String> staged;

  /// Secret positions whose binding the Host described (the dsh-go bridge),
  /// by [FieldRef.key]: the credential each is bound to, or null for a bare
  /// secret that is not written here.
  final Map<String, String?> secretBindings;

  /// A bare secret: the plugin has to bind it to a credential first.
  bool secretUnbound(FieldRef secret) => secretBindings.containsKey(secret.key) && secretBindings[secret.key] == null;
  final bool local;
  final String? _hostLabel;

  /// The connection generation that produced this snapshot (not serialized).
  final Object? _origin;
  String get hostLabel => _hostLabel ?? appL10n.commonThisPhone;

  SettingsNamespaceView? operator [](String ns) => namespaces[ns];

  bool served(String ns) => namespaces.containsKey(ns);

  SchemaNode? nodeOf(FieldRef field) {
    final view = namespaces[field.ns];
    return view == null ? null : schemaAt(view.schema, field.path);
  }

  /// The resolved value; null when unset.
  Object? valueOf(FieldRef field) => lookupPath(namespaces[field.ns]?.value, field.path).$2;

  /// What the field falls back to without a user value: the composition's
  /// value, else the schema default, else [fallback].
  Object? inheritedOf(FieldRef field, {Object? fallback}) {
    final view = namespaces[field.ns];
    if (view == null) return fallback;
    final (inBase, base) = lookupPath(view.base, field.path);
    if (inBase && base != null) return base;
    final node = schemaAt(view.schema, field.path)?.effective;
    if (node != null && node.meta.hasDefault && node.meta.defaultValue != null) return node.meta.defaultValue;
    return fallback;
  }

  /// Whole namespace decided above the profile: refused once, or its values
  /// differ from what its layers give. Every row of a form asks (twice) and
  /// the answer walks the whole namespace: worked out once per snapshot.
  bool isLocked(String ns) => (_lockedOf[this] ??= <String, bool>{})[ns] ??= _isLocked(ns);

  bool _isLocked(String ns) {
    if (locked.contains(ns)) return true;
    final view = namespaces[ns];
    if (view == null) return false;
    final fields = schemaObjectFields(view.schema);
    if (fields == null) return false;
    for (final MapEntry(:key, :value) in fields.entries) {
      if (value.effective.isSecret) continue;
      if (_overridden(view, [key])) return true;
    }
    return false;
  }

  static bool _overridden(SettingsNamespaceView view, List<String> path) {
    final (inValue, value) = lookupPath(view.value, path);
    final (inUser, user) = lookupPath(view.user, path);
    // A user object sets some of a group's fields: the rest come from below.
    if (inUser && user is Map && value is Map) {
      return {...user.keys, ...value.keys}.any((key) => _overridden(view, [...path, '$key']));
    }
    if (inUser) return inValue && !jsonEquals(value, user);
    final (inBase, base) = lookupPath(view.base, path);
    if (!inBase || view.base == null) return false;
    return !jsonEquals(inValue ? value : null, base);
  }

  FieldLayer layerOf(FieldRef field) {
    final view = namespaces[field.ns];
    if (view == null) return FieldLayer.inherited;
    if (isLocked(field.ns)) return FieldLayer.locked;
    return lookupPath(view.user, field.path).$1 ? FieldLayer.user : FieldLayer.inherited;
  }

  /// Writes can go to [ns] now.
  bool canWrite(String ns) => writable && (namespaces[ns]?.writable ?? false) && !isLocked(ns);

  bool isSaving(FieldRef field) => saving.contains(field.key);

  bool isStaged(FieldRef field) => staged.contains(field.key);

  String? errorOf(FieldRef field) => errors[field.key];

  /// The credential a secret field is read from: the value of a sibling
  /// `role('credential-ref')` field (or its default). Null when the secret is
  /// stored in the settings document itself.
  String? credentialRefOf(FieldRef secret) {
    if (secretBindings.containsKey(secret.key)) return secretBindings[secret.key];
    final view = namespaces[secret.ns];
    if (view == null || secret.path.isEmpty) return null;
    final parentPath = secret.path.sublist(0, secret.path.length - 1);
    final parent = parentPath.isEmpty ? view.schema : schemaAt(view.schema, parentPath);
    final fields = parent?.fields;
    if (fields == null) return null;
    for (final MapEntry(:key, :value) in fields.entries) {
      if (!value.effective.isCredentialRef) continue;
      final current = lookupPath(view.value, [...parentPath, key]).$2;
      if (current is String && current.isNotEmpty) return current;
      final fallback = value.effective.meta.defaultValue;
      if (fallback is String && fallback.isNotEmpty) return fallback;
    }
    return null;
  }

  /// A secret field holds a value (credential store or settings document).
  bool secretConfigured(FieldRef secret) {
    final slots = namespaces[secret.ns]?.secrets ?? const [];
    final slotSet = slots.any((s) => listEquals(s.path, secret.path) && s.set);
    final ref = credentialRefOf(secret);
    if (ref != null) return credentials[ref]?.configured ?? (secretBindings.containsKey(secret.key) && slotSet);
    return slotSet;
  }

  /// The secret can be written: the launch environment does not supply it.
  bool secretWritable(FieldRef secret) {
    if (secretUnbound(secret)) return false;
    final ref = credentialRefOf(secret);
    if (ref != null) return credentials[ref]?.writable ?? true;
    return canWrite(secret.ns);
  }

  EngineSettings copyWith({
    Map<String, SettingsNamespaceView>? namespaces,
    bool? writable,
    Map<String, CredentialStatus>? credentials,
    Set<String>? saving,
    Map<String, String>? errors,
    Set<String>? locked,
    Set<String>? staged,
    Map<String, String?>? secretBindings,
  }) => EngineSettings(
    namespaces: namespaces ?? this.namespaces,
    writable: writable ?? this.writable,
    credentials: credentials ?? this.credentials,
    saving: saving ?? this.saving,
    errors: errors ?? this.errors,
    locked: locked ?? this.locked,
    staged: staged ?? this.staged,
    secretBindings: secretBindings ?? this.secretBindings,
    local: local,
    hostLabel: _hostLabel,
    origin: _origin,
  );
}

/// The credential references secret fields of [namespaces] read from, and
/// the ones the media plugin's services name (whether a service can generate
/// depends on its key being there: media-generation §4.3).
Set<String> credentialRefsOf(Map<String, SettingsNamespaceView> namespaces) {
  final probe = EngineSettings(namespaces: namespaces);
  return {
    for (final view in namespaces.values)
      for (final slot in view.secrets) ?probe.credentialRefOf(FieldRef(view.ns, slot.path)),
    ...mediaKeyRefsOf(namespaces),
  };
}

/// [view] with [ops] applied the way the Host applies them: `set` writes the
/// value and the user layer, `unset` drops the user value and falls back to
/// the composition (or the schema default).
SettingsNamespaceView applyOps(SettingsNamespaceView view, List<SettingsOp> ops) {
  var value = view.value;
  var user = view.user ?? const <String, Object?>{};
  for (final op in ops) {
    if (op.op == 'set') {
      value = withPath(value, op.path, op.value);
      user = withPath(user, op.path, op.value);
    } else {
      final (inBase, base) = lookupPath(view.base, op.path);
      final node = schemaAt(view.schema, op.path)?.effective;
      final fallback = inBase ? base : (node?.meta.hasDefault ?? false ? node!.meta.defaultValue : null);
      value = fallback == null ? withoutPath(value, op.path) : withPath(value, op.path, fallback);
      user = withoutPath(user, op.path);
    }
  }
  return view.copyWith(value: value, user: user);
}

// ── Errors ───────────────────────────────────────────────────────────────────

/// A settings failure already in words.
class EngineSettingsFailure implements Exception {
  const EngineSettingsFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A schema bound in plain digits, or null when the Host text there is not a number.
String? _bound(String raw) {
  final n = num.tryParse(raw);
  if (n == null || !n.isFinite) return null;
  return n == n.roundToDouble() ? n.round().toString() : n.toString();
}

/// One short Chinese sentence for a failed settings or credentials call.
String describeSettingsError(Object error) {
  if (error is EngineSettingsFailure) return error.message;
  if (error is DshRemoteException) {
    final message = error.message;
    switch (error.code) {
      case 'settings/conflict':
        return appL10n.stateSettingsRefreshed;
      case 'credential/rejected':
        return appL10n.stateCredentialFromEnvironment;
    }
    if (engineErrorReason(error) case final reason?) return reason;
    if (message.contains('overridden by a home patch')) return appL10n.stateSettingsFromFile;
    if (RegExp(r'expected number >= (\S+)').firstMatch(message) case final m?) {
      if (_bound(m[1]!) case final bound?) return appL10n.stateSettingsMinimum(bound);
    }
    if (RegExp(r'expected number <= (\S+)').firstMatch(message) case final m?) {
      if (_bound(m[1]!) case final bound?) return appL10n.stateSettingsMaximum(bound);
    }
    if (RegExp(r'multiple of (\S+)').firstMatch(message) case final m?) {
      if (m[1] == '1') return appL10n.stateSettingsInteger;
      if (_bound(m[1]!) case final bound?) return appL10n.stateSettingsMultiple(bound);
    }
    if (message.contains('to match regexp')) return appL10n.stateSettingsInvalidFormat;
    if (RegExp(r'string length >= (\d+)').firstMatch(message) case final m?) {
      return appL10n.stateSettingsMinLength(int.parse(m[1]!));
    }
    if (RegExp(r'string length <= (\d+)').firstMatch(message) case final m?) {
      return appL10n.stateSettingsMaxLength(int.parse(m[1]!));
    }
    if (message.contains('read-only') || message.contains('not writable')) return appL10n.stateSettingsReadOnly;
    if (message.contains('No configurable plugin entry') || message.contains('no longer')) {
      return appL10n.statePluginDisabled;
    }
    if (message.contains('not volatile')) return appL10n.stateSettingsRestartRequired;
    if (message.contains('expected')) return appL10n.stateSettingsInvalidValue;
    return appL10n.stateSettingsRejected;
  }
  if (engineUnreachable(error)) return appL10n.commonEngineUnreachable;
  if (error is DshHttpException) return appL10n.stateEngineHttpRejected(error.statusCode);
  return appL10n.commonSaveFailed;
}

// ── Controller ───────────────────────────────────────────────────────────────

class _CredentialRead {
  _CredentialRead(this.refs, this.result);
  final Set<String> refs;
  final Future<Map<String, CredentialStatus>?> result;
  bool settled = false;
}

class _Write {
  _Write(this.ops, this.fields, this.seen);

  final List<SettingsOp> ops;
  final List<FieldRef> fields;

  /// What each field showed when the edit was made (conflict check).
  final Map<String, Object?> seen;
  bool retried = false;
}

/// What a schema form writes through: the engine's settings, or a plugin's
/// configuration (lib/state/plugin_config/).
abstract interface class SettingsEditor {
  void clearError(FieldRef field);

  /// False when nothing was sent or the write failed (the field carries why).
  Future<bool> set(FieldRef field, Object? value, {Object? fallback});
  Future<bool> reset(FieldRef field);

  /// Throws [EngineSettingsFailure].
  Future<void> setSecret(FieldRef field, String value);
  Future<void> clearSecret(FieldRef field);
}

/// A writer tied to the snapshot that opened an editor. The notifier is
/// reused across hosts; an editor must never acquire its newer destination.
class SettingsEditSession implements SettingsEditor {
  SettingsEditSession._(this._controller, this._snapshot);
  final EngineSettingsController _controller;
  final EngineSettings _snapshot;
  bool get active => _controller._accepts(_snapshot._origin);

  void _checkSecretTarget(FieldRef field) {
    if (!active) throw EngineSettingsFailure(_staleEditorMessage);
    final current = _controller._current;
    bool secret(SchemaNode? node) => node?.isSecret == true || node?.effective.isSecret == true;
    if (current == null ||
        !secret(_snapshot.nodeOf(field)) ||
        !secret(current.nodeOf(field)) ||
        _snapshot.credentialRefOf(field) != current.credentialRefOf(field)) {
      throw EngineSettingsFailure(appL10n.engineSecretTargetChanged);
    }
  }

  @override
  void clearError(FieldRef field) {
    if (active) _controller.clearError(field);
  }

  @override
  Future<bool> set(FieldRef field, Object? value, {Object? fallback}) =>
      active ? _controller.set(field, value, fallback: fallback) : Future.value(false);
  @override
  Future<bool> reset(FieldRef field) => active ? _controller.reset(field) : Future.value(false);
  Future<bool> write(String ns, List<SettingsOp> ops, {required List<FieldRef> fields}) =>
      active ? _controller.write(ns, ops, fields: fields) : Future.value(false);
  @override
  Future<void> setSecret(FieldRef field, String value) async {
    _checkSecretTarget(field);
    await _controller.setSecret(field, value);
  }

  @override
  Future<void> clearSecret(FieldRef field) async {
    _checkSecretTarget(field);
    await _controller.clearSecret(field);
  }

  /// Writes a credential the page names itself, against the snapshot this
  /// editor came from: a key sheet left open across a host switch must not
  /// store the key on the new host.
  Future<void> setCredential(String ref, String value) async {
    if (!active) throw EngineSettingsFailure(_staleEditorMessage);
    await _controller.setCredentialFor(_snapshot._origin!, ref, value);
  }

  /// Removes a directly named credential, with the same snapshot affinity.
  Future<void> clearCredential(String ref) async {
    if (!active) throw EngineSettingsFailure(_staleEditorMessage);
    await _controller.clearCredentialFor(_snapshot._origin!, ref);
  }
}

String get _staleEditorMessage => appL10n.engineSettingsHostChanged;

/// The active engine's settings; null while not connected. Re-read when the
/// engine says a namespace or a credential changed.
class EngineSettingsController extends AsyncNotifier<EngineSettings?> {
  DshClient? _client;
  MuxGeneration? _generation;
  Object _origin = Object();
  final Map<String, _CredentialRead> _credentialReads = {};
  final Map<String, CredentialStatus> _credentialCache = {};

  SettingsEditSession edit(EngineSettings snapshot) => SettingsEditSession._(this, snapshot);

  bool _accepts(Object? origin) {
    if (!ref.mounted || origin == null || !identical(origin, _origin) || _client == null) return false;
    final connection = ref.read(activeConnectionProvider);
    final mux = _client!.mux;
    return !connection.isLoading &&
        !connection.hasError &&
        identical(connection.value?.client, _client) &&
        identical(mux.generation, _generation) &&
        mux.state != DshConnectionState.reconnecting &&
        mux.state != DshConnectionState.unauthorized &&
        mux.state != DshConnectionState.closed;
  }

  /// What the Host last confirmed, per namespace (edits not applied).
  Map<String, SettingsNamespaceView> _confirmed = const {};
  bool _writable = true;
  // Latest full refresh request; superseded responses cannot publish.
  int _refreshEpoch = 0;
  // Writes and conflict reads invalidate descriptions already in flight.
  int _confirmedEpoch = 0;
  final Map<String, List<_Write>> _pending = {};
  final Map<String, Future<void>> _queues = {};
  Timer? _refreshTimer;

  @override
  Future<EngineSettings?> build() async {
    final connection = ref.watch(activeConnectionProvider);
    final conn = connection.isLoading || connection.hasError ? null : connection.value;
    final origin = _origin = Object();
    _client = conn?.client;
    _generation = conn?.client.mux.generation;
    _confirmed = const {};
    _credentialReads.clear();
    _credentialCache.clear();
    _refreshEpoch++;
    _confirmedEpoch++;
    _writable = true;
    _pending.clear();
    _queues.clear();
    if (conn == null) return null;
    final client = conn.client;
    final sub = client.hostEvents.listen((event) {
      if (!ref.mounted || !identical(origin, _origin)) return;
      if (event is HostReadyEvent && !identical(client.mux.generation, _generation)) {
        ref.invalidateSelf();
        return;
      }
      if (!_accepts(origin)) return;
      switch (event) {
        case SettingsUpdatedEvent() || HostReadyEvent():
          _scheduleRefresh();
        case CredentialUpdatedEvent():
          unawaited(_refreshCredentials());
        case UnknownHostEvent(:final event) when event == 'credentials/record-updated':
          unawaited(_refreshCredentials());
        default:
      }
    });
    ref.onDispose(() {
      if (identical(origin, _origin)) {
        _origin = Object();
        _client = null;
        _refreshTimer?.cancel();
      }
      unawaited(sub.cancel());
    });
    final described = await client.describeSettings();
    if (!_accepts(origin)) return null;
    final credentialRead = _startCredentialRead(client, described.namespaces);
    final credentials = await credentialRead.result;
    if (!_accepts(origin)) return null;
    _acceptCredentialRead(credentialRead, credentials);
    _confirmed = described.namespaces;
    _writable = described.writable;
    return EngineSettings(
      namespaces: described.namespaces,
      writable: described.writable,
      credentials: _credentialsFor(described.namespaces),
      local: conn.isLocal,
      hostLabel: conn.label,
      origin: origin,
    );
  }

  static Future<Map<String, CredentialStatus>?> _readCredentials(DshClient client, Set<String> refs) async {
    if (refs.isEmpty) return const {};
    try {
      return await client.describeCredentials(refs.toList());
    } catch (_) {
      return null;
    }
  }

  _CredentialRead _startCredentialRead(DshClient client, Map<String, SettingsNamespaceView> namespaces) {
    final refs = credentialRefsOf(namespaces);
    final read = _CredentialRead(refs, _readCredentials(client, refs));
    for (final ref in refs) {
      _credentialReads[ref] = read;
    }
    return read;
  }

  void _acceptCredentialRead(_CredentialRead read, Map<String, CredentialStatus>? values) {
    read.settled = true;
    if (values == null) return; // A failed latest read preserves known status.
    for (final ref in read.refs) {
      if (!identical(_credentialReads[ref], read)) continue;
      final value = values[ref];
      if (value == null) {
        _credentialCache.remove(ref);
      } else {
        _credentialCache[ref] = value;
      }
    }
  }

  Map<String, CredentialStatus> _credentialsFor(Map<String, SettingsNamespaceView> namespaces) => {
    for (final ref in credentialRefsOf(namespaces)) ref: ?_credentialCache[ref],
  };

  EngineSettings? get _current {
    final current = state.value;
    return current != null && _accepts(current._origin) ? current : null;
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), () => unawaited(refresh().catchError((Object _) {})));
  }

  /// Re-reads every namespace; ones with writes in flight keep their edits.
  Future<void> refresh() async {
    final origin = _origin;
    final client = _client;
    if (client == null) return;
    // An initial build has not published a snapshot yet. Finish that
    // generation before refreshing, so its late return cannot undo this read.
    if (_current == null) {
      await future;
      if (!_accepts(origin)) return;
    }
    final refreshEpoch = ++_refreshEpoch;
    bool current() => _accepts(origin) && refreshEpoch == _refreshEpoch;
    for (var attempt = 0; attempt < 2 && current(); attempt++) {
      final confirmedEpoch = _confirmedEpoch;
      final described = await client.describeSettings();
      if (!current()) return;
      final credentialRead = _startCredentialRead(client, described.namespaces);
      final credentials = await credentialRead.result;
      if (!_accepts(origin)) return;
      _acceptCredentialRead(credentialRead, credentials);
      if (!current()) return;
      // A write acknowledgement or conflict read superseded the snapshot
      // while this read was in flight. Re-read so other namespaces and
      // profile permissions still refresh; never publish the stale view.
      if (confirmedEpoch != _confirmedEpoch) continue;
      _confirmed = {
        for (final MapEntry(:key, :value) in described.namespaces.entries)
          key: (_pending[key]?.isNotEmpty ?? false) ? (_confirmed[key] ?? value) : value,
      };
      _writable = described.writable;
      _publish();
      return;
    }
    // Sustained writes must not turn one refresh into an unbounded RPC loop.
    // Keep confirmed data and coalesce another read through the existing timer.
    if (current()) _scheduleRefresh();
  }

  Future<void> _refreshCredentials() async {
    final origin = _origin;
    final client = _client;
    final current = _current;
    if (client == null || current == null) return;
    var reads = {_startCredentialRead(client, current.namespaces)};
    while (_accepts(origin)) {
      for (final read in reads) {
        final credentials = await read.result;
        if (!_accepts(origin)) return;
        _acceptCredentialRead(read, credentials);
      }
      // Follow only existing requests for the currently visible refs. A full
      // refresh may be reading a different, not-yet-published schema. Waiting
      // here creates no RPCs and never waits again on a settled request.
      reads = {
        for (final ref in credentialRefsOf(_current!.namespaces))
          if (_credentialReads[ref] case final read? when !read.settled) read,
      };
      if (reads.isEmpty) {
        _publish();
        return;
      }
    }
  }

  /// Rebuilds the visible state: confirmed views with pending edits on top.
  void _publish({Map<String, String>? errors, Set<String>? locked}) {
    final current = _current;
    if (current == null || !ref.mounted) return;
    final namespaces = {
      for (final MapEntry(:key, :value) in _confirmed.entries)
        key: (_pending[key] ?? const <_Write>[]).fold(value, (view, write) => applyOps(view, write.ops)),
    };
    state = AsyncData(
      current.copyWith(
        namespaces: namespaces,
        writable: _writable,
        credentials: _credentialsFor(namespaces),
        saving: {
          for (final writes in _pending.values)
            for (final write in writes)
              for (final field in write.fields) field.key,
        },
        errors: errors,
        locked: locked,
      ),
    );
  }

  /// Sets one field. A value equal to what the field inherits clears the user
  /// value instead of storing a copy of it. False when nothing was sent.
  Future<bool> set(FieldRef field, Object? value, {Object? fallback}) {
    final current = _current;
    if (current == null) return Future.value(false);
    final inherited = current.inheritedOf(field, fallback: fallback);
    final inUser = lookupPath(current[field.ns]?.user, field.path).$1;
    if (jsonEquals(value, inherited)) {
      // Already inherited: nothing to send.
      if (!inUser) return Future.value(false);
      return write(field.ns, [SettingsOp.unset(field.path)], fields: [field]);
    }
    return write(field.ns, [SettingsOp.set(field.path, value)], fields: [field]);
  }

  /// Back to the inherited value.
  Future<bool> reset(FieldRef field) => write(field.ns, [SettingsOp.unset(field.path)], fields: [field]);

  /// Applies [ops] to [ns] together (optimistically); [fields] are marked
  /// saving and carry the failure. Resolves to whether the Host took it.
  Future<bool> write(String ns, List<SettingsOp> ops, {required List<FieldRef> fields}) {
    final current = _current;
    final client = _client;
    if (current == null || client == null || ops.isEmpty) return Future.value(false);
    if (!current.canWrite(ns)) return Future.value(false);
    final origin = _origin;
    final write = _Write(ops, fields, {for (final f in fields) f.key: current.valueOf(f)});
    (_pending[ns] ??= []).add(write);
    _publish(errors: {...current.errors}..removeWhere((key, _) => fields.any((f) => f.key == key)));
    final completer = Completer<bool>();
    final previous = _queues[ns] ?? Future<void>.value();
    _queues[ns] = previous.then((_) async {
      final ok = await _send(client, ns, write, origin);
      if (!completer.isCompleted) completer.complete(ok);
    });
    return completer.future;
  }

  Future<bool> _send(DshClient client, String ns, _Write write, Object origin) async {
    if (!_accepts(origin)) return false;
    var errors = <String, String>{};
    var locked = <String>{};
    var ok = false;
    final base = _confirmed[ns];
    if (!write.retried && base != null && !_holds(base, write)) {
      // Made on top of something the Host doesn't confirm: an earlier edit of
      // the field, still in flight then, was refused, or a read since brought
      // someone else's value. Not sent on a revision it never saw (CR-e0b8ece
      // B1); the field shows what the Host has, with the earlier reason.
      final current = _current;
      errors = {for (final f in write.fields) f.key: current?.errors[f.key] ?? appL10n.stateSettingsRefreshed};
    } else {
      try {
        final confirmed = _confirmed[ns];
        final view = await client.mutateSettingsView(
          ns,
          write.ops,
          expectedRevision: confirmed?.revision,
          writable: confirmed?.writable ?? _writable,
        );
        if (_accepts(origin)) {
          _confirmedEpoch++;
          _confirmed = {..._confirmed, ns: view};
        }
        ok = true;
      } on DshRemoteException catch (error) {
        if (error.code == 'settings/conflict' && !write.retried) {
          write.retried = true;
          final retry = await _resolveConflict(client, ns, write, origin);
          if (retry) return _send(client, ns, write, origin);
          errors = {for (final f in write.fields) f.key: appL10n.stateSettingsRefreshed};
        } else {
          final message = describeSettingsError(error);
          if (error.message.contains('overridden by a home patch')) locked = {ns};
          errors = {for (final f in write.fields) f.key: message};
        }
      } catch (error) {
        errors = {for (final f in write.fields) f.key: describeSettingsError(error)};
      }
    }
    if (!_accepts(origin)) return false;
    _pending[ns]?.remove(write);
    final current = _current;
    _publish(
      errors: errors.isEmpty ? null : {...?current?.errors, ...errors},
      locked: locked.isEmpty ? null : {...?current?.locked, ...locked},
    );
    return ok;
  }

  /// Re-reads [ns] after a stale revision. True when the fields this write
  /// touches still hold what the user saw (someone changed something else):
  /// then the write goes again on the new revision.
  Future<bool> _resolveConflict(DshClient client, String ns, _Write write, Object origin) async {
    if (!_accepts(origin)) return false;
    try {
      final described = await client.describeSettings();
      final fresh = described.namespaces[ns];
      if (fresh == null || !_accepts(origin)) return false;
      _confirmedEpoch++;
      _confirmed = {..._confirmed, ns: fresh};
      return _holds(fresh, write);
    } catch (_) {
      return false;
    }
  }

  /// [confirmed] still holds in [write]'s fields what the user saw when
  /// making it.
  static bool _holds(SettingsNamespaceView confirmed, _Write write) =>
      write.fields.every((f) => jsonEquals(lookupPath(confirmed.value, f.path).$2, write.seen[f.key]));

  /// Clears a field's failure (the user is editing it again).
  void clearError(FieldRef field) {
    final current = _current;
    if (current == null || !current.errors.containsKey(field.key)) return;
    _publish(errors: {...current.errors}..remove(field.key));
  }

  /// Stores a secret: in the credential store when the field names a
  /// reference (as the official pages do), otherwise in the settings
  /// document. Throws [EngineSettingsFailure].
  Future<void> setSecret(FieldRef field, String value) async {
    final origin = _origin;
    final client = _client;
    final current = _current;
    if (client == null || current == null) throw EngineSettingsFailure(appL10n.commonEngineUnreachable);
    final ref = current.credentialRefOf(field);
    if (ref == null) {
      final ok = await write(field.ns, [SettingsOp.set(field.path, value)], fields: [field]);
      if (!ok) throw EngineSettingsFailure(_current?.errorOf(field) ?? appL10n.commonSaveFailed);
      return;
    }
    try {
      await client.setProviderKey(value, ref: ref);
    } catch (error) {
      throw EngineSettingsFailure(describeSettingsError(error));
    }
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    await _refreshCredentials();
  }

  /// Removes a secret. Throws [EngineSettingsFailure].
  Future<void> clearSecret(FieldRef field) async {
    final origin = _origin;
    final client = _client;
    final current = _current;
    if (client == null || current == null) throw EngineSettingsFailure(appL10n.commonEngineUnreachable);
    final ref = current.credentialRefOf(field);
    if (ref == null) {
      final ok = await write(field.ns, [SettingsOp.unset(field.path)], fields: [field]);
      if (!ok) throw EngineSettingsFailure(_current?.errorOf(field) ?? appL10n.commonSaveFailed);
      return;
    }
    try {
      await client.clearProviderKey(ref: ref);
    } catch (error) {
      throw EngineSettingsFailure(describeSettingsError(error));
    }
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    await _refreshCredentials();
  }

  /// Stores a credential the page names itself, not one a schema field
  /// declares. The media settings page gives every service its own
  /// environment-style reference (`DSH_MEDIA_<SERVICE>_API_KEY`), so its key
  /// rows write here instead of through a fixed secret slot. Throws
  /// [EngineSettingsFailure]; the host decides whether [ref] may be written.
  Future<void> setCredential(String ref, String value) => setCredentialFor(_origin, ref, value);

  /// [setCredential] against the host generation [origin] the caller's
  /// snapshot came from, so a page or sheet built against an older host
  /// cannot acquire the new one's credential store.
  Future<void> setCredentialFor(Object origin, String ref, String value) async {
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    final client = _client;
    if (client == null || _current == null) throw EngineSettingsFailure(appL10n.commonEngineUnreachable);
    try {
      await client.setProviderKey(value, ref: ref);
    } catch (error) {
      throw EngineSettingsFailure(describeSettingsError(error));
    }
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    await _refreshCredentials();
  }

  /// Removes a credential named directly, as [setCredential] wrote it.
  Future<void> clearCredential(String ref) => clearCredentialFor(_origin, ref);

  /// [clearCredential] against the snapshot's host generation.
  Future<void> clearCredentialFor(Object origin, String ref) async {
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    final client = _client;
    if (client == null || _current == null) throw EngineSettingsFailure(appL10n.commonEngineUnreachable);
    try {
      await client.clearProviderKey(ref: ref);
    } catch (error) {
      throw EngineSettingsFailure(describeSettingsError(error));
    }
    if (!_accepts(origin)) throw EngineSettingsFailure(_staleEditorMessage);
    await _refreshCredentials();
  }
}

final engineSettingsProvider = AsyncNotifierProvider<EngineSettingsController, EngineSettings?>(
  EngineSettingsController.new,
  retry: (_, _) => null,
);

// ── Plugin inventory ─────────────────────────────────────────────────────────

/// How an inventory row reads.
enum InventoryStatus {
  running,
  off,
  failed,
  loading,
  waiting,
  idle,
  conditional;

  String get label => switch (this) {
    running => appL10n.stateInventoryEnabled,
    off => appL10n.stateInventoryDisabled,
    failed => appL10n.stateAgentError,
    loading => appL10n.stateLoading,
    waiting => appL10n.stateInventoryWaiting,
    idle => appL10n.stateNotRunning,
    conditional => appL10n.stateInventoryConditional,
  };
}

InventoryStatus inventoryStatus({required bool enabled, String? fiberPhase, bool conditional = false}) {
  if (fiberPhase == 'failed') return InventoryStatus.failed;
  if (conditional) return InventoryStatus.conditional;
  if (!enabled) return InventoryStatus.off;
  return switch (fiberPhase) {
    'active' => InventoryStatus.running,
    'loading' || 'unloading' => InventoryStatus.loading,
    'pending' => InventoryStatus.waiting,
    _ => InventoryStatus.idle,
  };
}

/// `@deepseek-ai/dsh-web-app` → `web-app`; `cordis-plugin-timer` → `timer`.
String shortModuleName(String name) {
  var short = name;
  final slash = short.lastIndexOf('/');
  if (short.startsWith('@') && slash > 0) short = short.substring(slash + 1);
  for (final prefix in const ['cordis:', 'cordis-plugin-', 'dsh-host-', 'dsh-client-', 'dsh-']) {
    if (short.startsWith(prefix) && short.length > prefix.length) {
      short = short.substring(prefix.length);
      break;
    }
  }
  return short;
}

/// The bundles the app's own pages name in words.
Map<String, String> get _bundleNames => {
  '@deepseek-ai/dsh-base': appL10n.stateBundleBuiltIn,
  '@deepseek-ai/dsh-web-app': appL10n.commonWeb,
  '@deepseek-ai/dsh-sdk-minimal': 'SDK',
  '@deepseek-ai/dsh-sdk-app': 'SDK',
  '@deepseek-ai/dsh-headless': appL10n.stateBundleHeadless,
  '@deepseek-ai/dsh-acp-app': 'ACP',
};

/// One inventory row with where it came from.
@immutable
class InventoryItem {
  const InventoryItem({
    required this.entryId,
    required this.moduleName,
    required this.title,
    required this.status,
    this.description,
    this.icon,
    this.source,
    this.bundle,
    this.version,
    this.condition,
    this.metaError,
    this.enabledIn = const [],
    this.system = false,
  });

  final String entryId;
  final String moduleName;
  final String title;
  final String? description;
  final String? icon;
  final InventoryStatus status;

  /// The bundle that brings it, in words (「DSH 内置」, 「智能体团队」).
  final String? source;

  /// Package name of that bundle.
  final String? bundle;
  final String? version;

  /// A preset row's disabled expression.
  final String? condition;
  final String? metaError;

  /// Presets that compose it (global rows provided per session).
  final List<String> enabledIn;

  /// The package carries no Chinese name: an internal component, listed
  /// under 「系统组件」 by its package id.
  final bool system;

  /// The bundle row id, which is also its settings namespace.
  String get rowId => entryId.startsWith('include:') ? entryId.substring('include:'.length) : entryId;

  bool matches(List<String> terms) {
    if (terms.isEmpty) return true;
    final hay = [title, ?description, moduleName, entryId, ?source].join('\n').toLowerCase();
    return terms.every(hay.contains);
  }
}

final _cjk = RegExp(r'[\u3400-\u9fff]');

/// The Chinese variant of a package text (`zh`, `zh-CN`…, or plain text
/// written in Chinese); null when the package has none — English is never
/// shown in its place.
String? chineseText(LocalizedText? text) {
  if (text == null) return null;
  for (final MapEntry(:key, :value) in text.values.entries) {
    if ((key == 'zh' || key.startsWith('zh-')) && value.trim().isNotEmpty) return value.trim();
  }
  final plain = text.values[''];
  return plain != null && _cjk.hasMatch(plain) ? plain.trim() : null;
}

/// The inventory joined with the bundle list: titles in Chinese, the bundle
/// and version each entry comes from. Pure for testing.
({List<InventoryItem> global, Map<String, List<InventoryItem>> presets}) inventoryItems(
  PluginInventory inventory,
  List<PluginBundle> bundles,
) {
  ({String? source, String? bundle, String? version}) origin(String? entryId, String moduleName) {
    PluginBundle? owner;
    for (final b in bundles) {
      if (!b.rows.any((r) => (entryId != null && r.entryId == entryId) || r.moduleName == moduleName)) continue;
      if (owner == null || (!owner.enabled && b.enabled)) owner = b;
    }
    if (owner == null) {
      if (entryId != null && !entryId.startsWith('include') && RegExp(r'^[0-9a-f]{6,}$').hasMatch(entryId)) {
        return (source: appL10n.stateConfigFile, bundle: null, version: null);
      }
      return (source: null, bundle: null, version: null);
    }
    final title = owner.meta?.title?.resolve('zh');
    final name =
        _bundleNames[owner.name] ?? (title == null || title == owner.name ? shortModuleName(owner.name) : title);
    return (source: name, bundle: owner.name, version: owner.version);
  }

  String titleOf(PluginDisplayMeta? meta, String moduleName) => chineseText(meta?.title) ?? shortModuleName(moduleName);

  final providedBy = <String, List<String>>{};
  for (final preset in inventory.presets) {
    for (final row in preset.rows) {
      if (row.enabled || row.conditional) {
        (providedBy[row.moduleName] ??= []).add(preset.name ?? preset.id);
      }
    }
  }

  final global = [
    for (final e in inventory.entries)
      () {
        final from = origin(e.entryId, e.moduleName);
        return InventoryItem(
          entryId: e.entryId,
          moduleName: e.moduleName,
          title: titleOf(e.meta, e.moduleName),
          description: chineseText(e.meta?.description),
          system: chineseText(e.meta?.title) == null,
          icon: e.meta?.icon,
          status: inventoryStatus(enabled: e.enabled, fiberPhase: e.fiberPhase),
          source: from.source,
          bundle: from.bundle,
          version: from.version,
          metaError: e.meta?.error,
          enabledIn: e.enabled ? const [] : (providedBy[e.moduleName] ?? const []),
        );
      }(),
  ];
  final presets = {
    for (final preset in inventory.presets)
      preset.id: [
        for (final row in preset.rows)
          () {
            final from = origin(row.entryId == null ? null : 'include:${row.entryId}', row.moduleName);
            return InventoryItem(
              entryId: row.entryId ?? row.moduleName,
              moduleName: row.moduleName,
              title: titleOf(row.meta, row.moduleName),
              description: chineseText(row.meta?.description),
              system: chineseText(row.meta?.title) == null,
              icon: row.meta?.icon,
              status: inventoryStatus(enabled: row.enabled, fiberPhase: row.fiberPhase, conditional: row.conditional),
              source: from.source,
              bundle: from.bundle,
              version: from.version,
              condition: row.condition,
              metaError: row.meta?.error,
            );
          }(),
      ],
  };
  return (global: global, presets: presets);
}

/// The inventory as the page shows it.
@immutable
class InventorySnapshot {
  const InventorySnapshot({required this.inventory, required this.global, required this.presets});

  final PluginInventory inventory;
  final List<InventoryItem> global;

  /// Rows of each preset's composition, by preset id.
  final Map<String, List<InventoryItem>> presets;
}

/// `pluginInventory/list` of the active host (`pluginManager/listPlugins`
/// where the relay does not let it through), joined with the bundle list;
/// refreshed on plugin changes. Null while not connected.
final pluginInventoryProvider = FutureProvider.autoDispose<InventorySnapshot?>((ref) async {
  final conn = ref.watch(activeConnectionProvider.select((c) => c.value));
  if (conn == null) return null;
  final client = conn.client;
  final sub = client.pluginManagerEvents.listen((event) {
    if (event is PluginManagerChangedEvent) ref.invalidateSelf();
  });
  final ready = client.hostEvents.listen((event) {
    if (event is HostReadyEvent) ref.invalidateSelf();
  });
  ref.onDispose(() {
    unawaited(sub.cancel());
    unawaited(ready.cancel());
  });
  PluginInventory inventory;
  try {
    inventory = await client.pluginInventory();
  } on DshRemoteException catch (error, stack) {
    // The relay's allow-list (or an older Host) has no inventory Remote.
    try {
      inventory = PluginInventory.fromEntries(await client.listPlugins());
    } catch (_) {
      Error.throwWithStackTrace(error, stack);
    }
  }
  final bundles = await ref.watch(installedPluginsProvider.future).catchError((Object _) => null) ?? const [];
  final items = inventoryItems(inventory, bundles);
  return InventorySnapshot(inventory: inventory, global: items.global, presets: items.presets);
}, retry: (_, _) => null);
