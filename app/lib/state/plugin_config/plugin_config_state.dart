// The native plugin configuration of the active Host (docs/design/
// plugin-config.md): every plugin entry's form, edits to live fields sent at
// once, edits to the rest held until 保存 and applied together with a reload,
// the apply's progress, and a failed apply that can be retried, put back or
// dropped.
//
// The Host owns the values. A live write is optimistic and per namespace in
// order, each against the revision the previous one returned; held edits sit
// on top of what the Host confirmed until they are saved or dropped. What the
// Host confirmed (the form and its revision) is kept apart from the writes in
// flight: a re-read always replaces it. A live write refused because the
// entry changed re-reads it and goes again against the new revision only when
// its fields still hold what the person saw.
//
// Only plugins (PluginConfigScope: rows of a bundle the person chose, from
// `pluginManager/listBundles`): the Host lists DSH's core too, and none of
// it is listed, read or written here, by the state or by the Host interface.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../connection_state.dart';
import '../engine_settings_state.dart';
import '../plugins_state.dart' show installedPluginsProvider, pluginHostProvider;
import '../read_list_cache.dart';
import '../read_list_identity.dart' show readListIdentityProvider;
import 'plugin_config_api.dart';
import 'plugin_config_bridge.dart';
import 'plugin_config_scope.dart';

export 'plugin_config_api.dart';
export 'plugin_config_bridge.dart' show BridgePluginConfigApi;
export 'plugin_config_scope.dart';

/// The active Host's plugins: rows of the bundles the person chose
/// ([PluginConfigScope.owns]), from the plugin list only while it is the
/// Host's latest successful answer on this connection and identity, and
/// confirmed (CR-a17797b). The list stays on screen through a refresh, a
/// failed one, or an optimistic switch; it grants nothing then:
/// [PluginConfigScope.none] while being read or not yet confirmed,
/// [PluginConfigScope.failed] after a failed read, [PluginConfigScope.offline]
/// without a plugin manager to ask.
final pluginConfigScopeProvider = Provider<PluginConfigScope>((ref) {
  final host = ref.watch(pluginHostProvider);
  if (host == null) return PluginConfigScope.offline;
  final source = ref.watch(installedPluginsProvider);
  final identity = ref.watch(readListIdentityProvider);
  final cache = ref.watch(readListCacheProvider);
  // A refresh starts and ends in the cache, not in the list (a failed one
  // keeps it): ask again on every change. (The cache's change stream emits
  // the same value each time, so watching it as a provider misses some.)
  final changes = cache.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  final bundles = source.value;
  final activity = cache.refresh(ReadListKind.plugins, identity, bundles);
  if (source.hasError || activity?.failed == true) return PluginConfigScope.failed;
  if (bundles == null || source.isLoading || activity?.pending == true) return PluginConfigScope.none;
  final origin = cache.origin(bundles);
  // Read over this connection, for this identity, and a Host answer rather
  // than an optimistic patch of one.
  if (origin == null || !origin.confirmed || !cache.current(bundles, identity, host.client)) {
    return PluginConfigScope.none;
  }
  return PluginConfigScope.of(bundles);
});

/// The Host interface the page runs on: the dsh-go bridge's complete plugin
/// configuration where the Host has it, else the live fields DSH serves
/// through the engine settings (the relay never reaches the bridge).
final pluginConfigApiProvider = Provider<PluginConfigApi?>((ref) {
  final changes = StreamController<void>.broadcast();
  ref.onDispose(changes.close);
  ref.listen(engineSettingsProvider, (_, _) => changes.add(null));
  final engine = EngineSettingsPluginConfigApi(ref, changes.stream);
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.canReachDshGo) return engine;
  final bridge = BridgePluginConfigApi(client, engine, scope: () => ref.read(pluginConfigScopeProvider));
  final restarts = client.hostEvents.listen((event) {
    if (event is HostReadyEvent) bridge.forget();
  });
  ref.onDispose(restarts.cancel);
  return bridge;
});

/// [PluginConfigApi] over DSH 0.2.1's `settings/describe` and
/// `settings/mutate`, through [engineSettingsProvider] (one read shared with
/// the engine pages, its ordered optimistic writes and conflict retry): only
/// `.volatile()` fields, every one of them live.
class EngineSettingsPluginConfigApi implements PluginConfigApi {
  EngineSettingsPluginConfigApi(this._ref, this.changes);

  final Ref _ref;

  @override
  final Stream<void> changes;

  @override
  Future<PluginConfigCatalog?> describe() async {
    final settings = await _ref.read(engineSettingsProvider.future);
    if (settings == null) return null;
    return PluginConfigCatalog(
      writable: settings.writable,
      forms: {
        for (final MapEntry(:key, :value) in settings.namespaces.entries) key: PluginConfigForm(value, allLive: true),
      },
    );
  }

  /// [ns] is a plugin's entry: else nothing is asked or sent for it.
  void _ensureInScope(String ns) {
    final scope = _ref.read(pluginConfigScopeProvider);
    if (!scope.allows(ns)) throw scope.refusal();
  }

  /// The credentials plugin namespaces in scope declare.
  Future<Set<String>> _credentialsInScope(PluginConfigScope scope) async {
    if (!scope.confirmed) return const {};
    final settings = await _ref.read(engineSettingsProvider.future);
    return {
      for (final view in settings?.namespaces.values ?? const <SettingsNamespaceView>[])
        if (scope.allows(view.ns)) ...PluginConfigForm(view, allLive: true).credentialRefs,
    };
  }

  /// [ref] is a credential a plugin namespace in scope declares: else it is
  /// not written.
  Future<void> _ensureCredentialInScope(String ref) async {
    final scope = _ref.read(pluginConfigScopeProvider);
    if (!(await _credentialsInScope(scope)).contains(ref)) throw scope.refusal();
  }

  @override
  Future<PluginConfigForm?> read(String ns) async {
    _ensureInScope(ns);
    return (await describe())?.forms[ns];
  }

  @override
  Stream<PluginConfigEvent> apply(String ns, List<SettingsOp> ops, {Object? revision}) async* {
    _ensureInScope(ns);
    yield const PluginConfigProgress(PluginConfigStep.saving);
    // The plugin list may have changed while the step was shown.
    _ensureInScope(ns);
    final fields = [for (final op in ops) FieldRef(ns, op.path)];
    final ok = await _ref.read(engineSettingsProvider.notifier).write(ns, ops, fields: fields);
    final settings = _ref.read(engineSettingsProvider).value;
    final view = settings?[ns];
    if (!ok || view == null) {
      final message = [for (final f in fields) ?settings?.errorOf(f)].firstOrNull;
      throw PluginConfigFailure(PluginConfigFailureKind.rejected, message ?? appL10n.commonSaveFailed);
    }
    yield PluginConfigApplied(PluginConfigForm(view, allLive: true));
  }

  @override
  Future<Map<String, CredentialStatus>> describeCredentials(Set<String> refs) async {
    final known = (await _ref.read(engineSettingsProvider.future))?.credentials ?? const {};
    final declared = await _credentialsInScope(_ref.read(pluginConfigScopeProvider));
    return {
      for (final ref in refs)
        if (declared.contains(ref)) ref: ?known[ref],
    };
  }

  DshClient get _client {
    final client = _ref.read(activeConnectionProvider).value?.client;
    if (client == null) {
      throw PluginConfigFailure(PluginConfigFailureKind.unreachable, appL10n.commonEngineUnreachable);
    }
    return client;
  }

  @override
  Future<void> setCredential(String ref, String value) async {
    await _ensureCredentialInScope(ref);
    try {
      await _client.setProviderKey(value, ref: ref);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
    await _ref.read(engineSettingsProvider.notifier).refresh().catchError((Object _) {});
  }

  @override
  Future<void> clearCredential(String ref) async {
    await _ensureCredentialInScope(ref);
    try {
      await _client.clearProviderKey(ref: ref);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
    await _ref.read(engineSettingsProvider.notifier).refresh().catchError((Object _) {});
  }
}

/// A save of one plugin's held edits.
@immutable
class PluginConfigJob {
  const PluginConfigJob({this.step, this.failure, this.done = false, this.ops = const [], this.undo = const []});

  /// Where the Host is while it runs.
  final PluginConfigStep? step;
  final PluginConfigFailure? failure;

  /// Took effect (shown briefly, then cleared).
  final bool done;

  /// What was sent.
  final List<SettingsOp> ops;

  /// What puts the previous values back (secrets excepted: never read).
  final List<SettingsOp> undo;

  bool get running => failure == null && !done;

  PluginConfigJob copyWith({PluginConfigStep? step, PluginConfigFailure? failure, bool? done}) => PluginConfigJob(
    step: step ?? this.step,
    failure: failure ?? this.failure,
    done: done ?? this.done,
    ops: ops,
    undo: undo,
  );
}

/// The plugin forms as the page reads them.
@immutable
class PluginConfigState {
  PluginConfigState({
    required this.forms,
    Map<String, PluginConfigEntry>? entries,
    this.lazy = false,
    this.loadErrors = const {},
    this.writable = true,
    this.complete = false,
    this.drafts = const {},
    this.pending = const {},
    this.saving = const {},
    this.errors = const {},
    this.jobs = const {},
    this.credentials = const {},
    this.local = true,
    this.hostLabel,
    this.scope = PluginConfigScope.none,
  }) : entries = entries ?? {for (final ns in forms.keys) ns: PluginConfigEntry(ns)};

  /// What the Host confirmed, by namespace: every form, or (with [lazy])
  /// the ones read so far. Only a plugin's is handed out ([operator []]).
  final Map<String, PluginConfigForm> forms;

  /// Every entry the Host lists, in its order: DSH's core included (its
  /// curated pages and the reasons an entry can't be set read it).
  final Map<String, PluginConfigEntry> entries;

  /// Which entries are plugins: the only ones listed, read or written here.
  final PluginConfigScope scope;

  /// Forms are read when their page opens ([PluginConfigController.load]).
  final bool lazy;

  /// Why a form could not be read, by namespace.
  final Map<String, String> loadErrors;
  final bool writable;

  /// The Host serves fields that need a reload, not only live ones.
  final bool complete;

  /// Held edits (fields that take effect on a reload), per namespace, in order.
  final Map<String, List<SettingsOp>> drafts;

  /// Live writes in flight, applied optimistically.
  final Map<String, List<SettingsOp>> pending;

  /// [FieldRef.key]s with a live write in flight.
  final Set<String> saving;

  /// Last failure by [FieldRef.key], in words.
  final Map<String, String> errors;

  /// A save per namespace (running, failed, or just done).
  final Map<String, PluginConfigJob> jobs;
  final Map<String, CredentialStatus> credentials;
  final bool local;
  final String? hostLabel;

  final Map<String, EngineSettings> _snapshots = {};

  /// [ns] is a plugin's entry ([scope], narrowed by what the Host lists:
  /// its package and bundle must match the bundle row's when it names them,
  /// its R7 owner must be a plugin's).
  bool isPlugin(String ns) => scope.admits(ns, entries[ns]);

  /// [ns]'s form, for a plugin only: an entry out of scope has none here,
  /// whatever the Host served.
  PluginConfigForm? operator [](String ns) => isPlugin(ns) ? forms[ns] : null;

  List<SettingsOp> draftOf(String ns) => drafts[ns] ?? const [];

  bool hasDraft(String ns) => draftOf(ns).isNotEmpty;

  PluginConfigJob? jobOf(String ns) => jobs[ns];

  bool isApplying(String ns) => jobs[ns]?.running ?? false;

  /// The namespace as its form shows it: confirmed values, live writes in
  /// flight and held edits on top; read-only while a save runs.
  EngineSettings settingsFor(String ns) => _snapshots[ns] ??= _snapshot(ns);

  EngineSettings _snapshot(String ns) {
    final form = this[ns];
    if (form == null) return EngineSettings(namespaces: const {}, local: local, hostLabel: hostLabel);
    var view = applyOps(form.view, pending[ns] ?? const []);
    final secretPaths = {for (final slot in view.secrets) slot.path.join('\u0000')};
    final draft = draftOf(ns);
    view = applyOps(view, [
      for (final op in draft)
        if (!secretPaths.contains(op.path.join('\u0000'))) op,
    ]);
    if (draft.any((op) => secretPaths.contains(op.path.join('\u0000')))) {
      SettingsSecretSlot held(SettingsSecretSlot slot) {
        final op = draft.where((op) => listEquals(op.path, slot.path)).lastOrNull;
        return op == null ? slot : SettingsSecretSlot(slot.path, set: op.op == 'set');
      }

      view = view.copyWith(secrets: [for (final slot in view.secrets) held(slot)]);
    }
    return EngineSettings(
      namespaces: {ns: view},
      writable: writable && !isApplying(ns),
      credentials: credentials,
      saving: saving,
      errors: errors,
      staged: {for (final op in draft) FieldRef(ns, op.path).key},
      secretBindings: form.secretBindings,
      local: local,
      hostLabel: hostLabel,
    );
  }

  PluginConfigState copyWith({
    Map<String, PluginConfigForm>? forms,
    Map<String, PluginConfigEntry>? entries,
    bool? lazy,
    Map<String, String>? loadErrors,
    bool? writable,
    bool? complete,
    Map<String, List<SettingsOp>>? drafts,
    Map<String, List<SettingsOp>>? pending,
    Set<String>? saving,
    Map<String, String>? errors,
    Map<String, PluginConfigJob>? jobs,
    Map<String, CredentialStatus>? credentials,
    PluginConfigScope? scope,
  }) => PluginConfigState(
    forms: forms ?? this.forms,
    entries: entries ?? this.entries,
    lazy: lazy ?? this.lazy,
    loadErrors: loadErrors ?? this.loadErrors,
    writable: writable ?? this.writable,
    complete: complete ?? this.complete,
    drafts: drafts ?? this.drafts,
    pending: pending ?? this.pending,
    saving: saving ?? this.saving,
    errors: errors ?? this.errors,
    jobs: jobs ?? this.jobs,
    credentials: credentials ?? this.credentials,
    local: local,
    hostLabel: hostLabel,
    scope: scope ?? this.scope,
  );
}

/// [ops] with [op] added: an earlier edit of the same field (or of a field
/// inside it) gives way.
List<SettingsOp> _withOp(List<SettingsOp> ops, SettingsOp op) {
  bool inside(List<String> path) =>
      path.length >= op.path.length && listEquals(path.sublist(0, op.path.length), op.path);
  return [
    for (final existing in ops)
      if (!inside(existing.path)) existing,
    op,
  ];
}

/// Held edits that would change nothing against [confirmed] are dropped (an
/// edit taken back by hand). A secret is never read back, so setting one
/// always counts.
List<SettingsOp> _effective(SettingsNamespaceView confirmed, List<SettingsOp> ops) {
  bool changes(SettingsOp op) {
    final slot = confirmed.secrets.where((slot) => listEquals(slot.path, op.path)).firstOrNull;
    if (slot != null) return op.op == 'set' || slot.set;
    final (present, value) = lookupPath(confirmed.user, op.path);
    return op.op == 'set' ? !present || !jsonEquals(value, op.value) : present;
  }

  return [
    for (final op in ops)
      if (changes(op)) op,
  ];
}

/// Puts [paths] of [confirmed]'s user layer back as they were.
///
/// Inferred from the user layer the Host last returned, not a transaction or
/// a full snapshot of the file: it restores plain values set or unset. An
/// unset of one array element is not idempotent, and a value the read masks
/// (an expression in the profile) can't be written back from what shows; the
/// page edits arrays only as whole-array sets, so neither is sent from here.
List<SettingsOp> _undoOf(SettingsNamespaceView confirmed, List<SettingsOp> ops) {
  final secretPaths = {for (final slot in confirmed.secrets) slot.path.join('\u0000')};
  return [
    for (final op in ops)
      if (!secretPaths.contains(op.path.join('\u0000')))
        switch (lookupPath(confirmed.user, op.path)) {
          (true, final value) => SettingsOp.set(op.path, value),
          _ => SettingsOp.unset(op.path),
        },
  ];
}

class PluginConfigController extends AsyncNotifier<PluginConfigState?> {
  PluginConfigApi? _api;
  Object _origin = Object();
  final Map<String, Future<void>> _queues = {};
  final Set<String> _loading = {};
  Timer? _refreshTimer;
  final Map<String, Timer> _doneTimers = {};

  /// How long 「已生效」 stays.
  static const doneFor = Duration(milliseconds: 1600);

  bool _accepts(Object origin) => ref.mounted && identical(origin, _origin);

  PluginConfigState? get _current => state.value;

  @override
  Future<PluginConfigState?> build() async {
    final api = _api = ref.watch(pluginConfigApiProvider);
    final conn = ref.watch(activeConnectionProvider.select((c) => c.value));
    final origin = _origin = Object();
    _queues.clear();
    _loading.clear();
    if (api == null) return null;
    final sub = api.changes.listen((_) {
      if (_accepts(origin)) _scheduleRefresh();
    });
    // The plugin list changed (installed, removed, switched): the same
    // entries, another scope. Held edits stay.
    ref.listen(pluginConfigScopeProvider, (_, next) {
      final current = _current;
      if (_accepts(origin) && current != null && current.scope != next) _set(current.copyWith(scope: next));
    });
    ref.onDispose(() {
      unawaited(sub.cancel());
      _refreshTimer?.cancel();
      for (final timer in _doneTimers.values) {
        timer.cancel();
      }
      _doneTimers.clear();
    });
    final catalog = await api.describe();
    if (catalog == null) return null;
    final credentials = await _credentials(api, catalog.forms);
    return PluginConfigState(
      forms: catalog.forms,
      entries: catalog.entries,
      lazy: catalog.lazy,
      writable: catalog.writable,
      complete: catalog.complete,
      credentials: credentials ?? const {},
      local: conn?.isLocal ?? true,
      hostLabel: conn?.label,
      scope: ref.read(pluginConfigScopeProvider),
    );
  }

  static Future<Map<String, CredentialStatus>?> _credentials(
    PluginConfigApi api,
    Map<String, PluginConfigForm> forms,
  ) async {
    final refs = {
      ...credentialRefsOf({for (final MapEntry(:key, :value) in forms.entries) key: value.view}),
      for (final form in forms.values) ...form.secretBindings.values.nonNulls,
    };
    try {
      return await api.describeCredentials(refs);
    } catch (_) {
      return null;
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), () => unawaited(refresh().catchError((Object _) {})));
  }

  /// Reads [ns]'s form when the Host serves forms one at a time (its page
  /// opened); a listed entry that cannot be configured is not asked for.
  Future<void> load(String ns) async {
    final api = _api;
    final origin = _origin;
    final current = _current;
    if (api == null || current == null || !current.lazy || current.forms.containsKey(ns)) return;
    if (current.entries[ns] case final entry? when !entry.configurable) return;
    // Not a plugin: its form is not asked for.
    if (!current.isPlugin(ns)) return;
    if (!_loading.add(ns)) return;
    try {
      final form = await api.read(ns);
      final credentials = form == null ? null : await _credentials(api, {ns: form});
      final latest = _current;
      if (!_accepts(origin) || latest == null) return;
      _set(
        latest.copyWith(
          forms: form == null ? null : {...latest.forms, ns: form},
          entries: form == null ? ({...latest.entries}..remove(ns)) : null,
          credentials: credentials == null ? null : {...latest.credentials, ...credentials},
          loadErrors: {...latest.loadErrors}..remove(ns),
        ),
      );
    } catch (error) {
      final latest = _current;
      if (!_accepts(origin) || latest == null) return;
      _set(latest.copyWith(loadErrors: {...latest.loadErrors, ns: pluginConfigFailureOf(error).message}));
    } finally {
      if (_accepts(origin)) _loading.remove(ns);
    }
  }

  /// Re-reads every entry (and every form read so far); held edits stay on
  /// top, and go when their plugin does.
  Future<void> refresh() async {
    final api = _api;
    final origin = _origin;
    if (api == null) return;
    if (_current == null) {
      await future;
      if (!_accepts(origin)) return;
    }
    final catalog = await api.describe();
    if (!_accepts(origin) || catalog == null) return;
    var forms = catalog.forms;
    if (catalog.lazy) {
      final open = [
        for (final ns in _current?.forms.keys ?? const <String>[])
          if (catalog.entries[ns]?.configurable ?? false) ns,
      ];
      final read = await Future.wait([
        for (final ns in open) api.read(ns).then<PluginConfigForm?>((f) => f, onError: (Object _) => _current?[ns]),
      ]);
      forms = {for (final (i, ns) in open.indexed) ns: ?read[i]};
    }
    final credentials = await _credentials(api, forms);
    final current = _current;
    if (!_accepts(origin) || current == null) return;
    state = AsyncData(
      current.copyWith(
        // What the Host confirmed, revision included. Live writes in flight
        // stay in [PluginConfigState.pending] and show on top of it; they
        // never hold the form at the revision they started from.
        forms: forms,
        entries: catalog.entries,
        lazy: catalog.lazy,
        writable: catalog.writable,
        complete: catalog.complete,
        drafts: {
          for (final MapEntry(:key, :value) in current.drafts.entries)
            if (forms[key] case final form?)
              if (_effective(form.view, value) case final ops when ops.isNotEmpty) key: ops,
        },
        credentials: {...current.credentials, ...?credentials},
      ),
    );
  }

  /// [form] is what the Host now confirms for [ns] (a fresh read): it becomes
  /// the base everything else sits on, and held edits it already has go.
  void _confirm(String ns, PluginConfigForm form) {
    final current = _current;
    if (current == null) return;
    final held = _effective(form.view, current.draftOf(ns));
    _set(
      current.copyWith(
        forms: {...current.forms, ns: form},
        drafts: {...current.drafts, ns: held}..removeWhere((_, v) => v.isEmpty),
      ),
    );
  }

  void _set(PluginConfigState next) {
    if (ref.mounted) state = AsyncData(next);
  }

  /// Sets one field: at once when it is live, held for 保存 otherwise. A
  /// value equal to what the field inherits clears the user's own instead.
  Future<bool> set(FieldRef field, Object? value, {Object? fallback}) {
    final current = _current;
    if (current == null || current[field.ns] == null) return Future.value(false);
    final snapshot = current.settingsFor(field.ns);
    final inherited = snapshot.inheritedOf(field, fallback: fallback);
    final inUser = lookupPath(snapshot[field.ns]?.user, field.path).$1;
    if (jsonEquals(value, inherited)) {
      if (!inUser) return Future.value(false);
      return _edit(field, SettingsOp.unset(field.path));
    }
    return _edit(field, SettingsOp.set(field.path, value));
  }

  /// Back to the inherited value.
  Future<bool> reset(FieldRef field) => _edit(field, SettingsOp.unset(field.path));

  Future<bool> _edit(FieldRef field, SettingsOp op) {
    final current = _current;
    final form = current?[field.ns];
    if (current == null || form == null || !current.settingsFor(field.ns).canWrite(field.ns)) {
      return Future.value(false);
    }
    if (form.isLive(field.path)) return _writeLive(field.ns, [op], fields: [field]);
    _hold(field.ns, op, field);
    return Future.value(true);
  }

  void _hold(String ns, SettingsOp op, FieldRef field) {
    final current = _current!;
    final form = current[ns]!;
    final ops = _effective(form.view, _withOp(current.draftOf(ns), op));
    final jobs = {...current.jobs};
    // A new edit after a failed save starts over.
    if (jobs[ns]?.running == false) jobs.remove(ns);
    _set(
      current.copyWith(
        drafts: {...current.drafts, ns: ops}..removeWhere((_, v) => v.isEmpty),
        errors: {...current.errors}..remove(field.key),
        jobs: jobs,
      ),
    );
  }

  Future<bool> _writeLive(String ns, List<SettingsOp> ops, {required List<FieldRef> fields}) {
    final api = _api;
    final current = _current;
    if (api == null || current == null) return Future.value(false);
    final origin = _origin;
    final seen = {for (final f in fields) f.key: current.settingsFor(ns).valueOf(f)};
    _set(
      current.copyWith(
        pending: {
          ...current.pending,
          ns: [...current.pending[ns] ?? const [], ...ops],
        },
        saving: {...current.saving, for (final f in fields) f.key},
        errors: {...current.errors}..removeWhere((key, _) => fields.any((f) => f.key == key)),
      ),
    );
    final completer = Completer<bool>();
    final previous = _queues[ns] ?? Future<void>.value();
    _queues[ns] = previous.then((_) async {
      final ok = await _sendLive(api, ns, ops, fields, seen, origin);
      if (!completer.isCompleted) completer.complete(ok);
    });
    return completer.future;
  }

  /// [form] (what the Host confirms) still holds in [fields] what the person
  /// saw ([seen]) when making the edit.
  static bool _holds(PluginConfigForm form, List<FieldRef> fields, Map<String, Object?> seen) =>
      fields.every((f) => jsonEquals(lookupPath(form.view.value, f.path).$2, seen[f.key]));

  /// Sends [ops] against [revision] (by default the confirmed form's). [seen]
  /// is what the person saw in [fields] before this edit.
  Future<bool> _sendLive(
    PluginConfigApi api,
    String ns,
    List<SettingsOp> ops,
    List<FieldRef> fields,
    Map<String, Object?> seen,
    Object origin, {
    Object? revision,
    bool retried = false,
  }) async {
    String? error;
    PluginConfigForm? applied;
    final base = _current?[ns];
    if (!retried && base != null && !_holds(base, fields, seen)) {
      // Made on top of something the Host doesn't confirm (CR-e0b8ece B1): an
      // earlier edit of the field, still in flight then, was refused, or a
      // read since brought someone else's value. Its revision is not this
      // edit's to use: not sent, the field shows what the Host has, with the
      // reason the earlier edit gave when it has one.
      error = [for (final f in fields) ?_current?.errors[f.key]].firstOrNull ?? appL10n.stateSettingsRefreshed;
    } else {
      try {
        await for (final event in api.apply(ns, ops, revision: revision ?? base?.revision)) {
          if (event is PluginConfigApplied) applied = event.form;
        }
      } on PluginConfigFailure catch (failure) {
        if (failure.kind == PluginConfigFailureKind.conflict && !retried && _accepts(origin)) {
          // The Host moved on. What this read returns is the new base, revision
          // and all, whether or not the edit goes again; it goes again only when
          // the fields still hold what the person saw (someone changed something
          // else), never over someone else's value for the same field.
          final fresh = await api.read(ns).then<PluginConfigForm?>((f) => f, onError: (Object _) => null);
          if (_accepts(origin)) {
            if (fresh == null) {
              // Gone or unreadable: the next full read says which.
              _scheduleRefresh();
            } else {
              _confirm(ns, fresh);
              if (_holds(fresh, fields, seen)) {
                return _sendLive(api, ns, ops, fields, seen, origin, revision: fresh.revision, retried: true);
              }
            }
          }
        }
        error = failure.message;
      } catch (e) {
        error = pluginConfigFailureOf(e).message;
      }
    }
    if (!_accepts(origin)) return false;
    final current = _current!;
    final rest = [...current.pending[ns] ?? const <SettingsOp>[]];
    for (final op in ops) {
      rest.remove(op);
    }
    _set(
      current.copyWith(
        forms: applied != null ? {...current.forms, ns: applied} : null,
        pending: {...current.pending, ns: rest}..removeWhere((_, v) => v.isEmpty),
        saving: {...current.saving}..removeAll(fields.map((f) => f.key)),
        errors: error == null ? null : {...current.errors, for (final f in fields) f.key: error},
      ),
    );
    return error == null;
  }

  /// Clears a field's failure (the person is editing it again).
  void clearError(FieldRef field) {
    final current = _current;
    if (current == null || !current.errors.containsKey(field.key)) return;
    _set(current.copyWith(errors: {...current.errors}..remove(field.key)));
  }

  /// Stores a secret: in the credential store when the field names a
  /// reference, otherwise with the plugin's values (held when it needs a
  /// reload). Throws [EngineSettingsFailure].
  Future<void> setSecret(FieldRef field, String value) => _secret(field, value);

  /// Removes a secret. Throws [EngineSettingsFailure].
  Future<void> clearSecret(FieldRef field) => _secret(field, null);

  Future<void> _secret(FieldRef field, String? value) async {
    final api = _api;
    final current = _current;
    if (api == null || current == null) throw EngineSettingsFailure(appL10n.commonEngineUnreachable);
    final snapshot = current.settingsFor(field.ns);
    // A bare secret would land in the profile file: not written here (§5).
    if (snapshot.secretUnbound(field)) throw EngineSettingsFailure(appL10n.pluginConfigSecretUnbound);
    final credential = snapshot.credentialRefOf(field);
    if (credential != null) {
      final origin = _origin;
      try {
        value == null ? await api.clearCredential(credential) : await api.setCredential(credential, value);
      } catch (error) {
        throw EngineSettingsFailure(pluginConfigFailureOf(error).message);
      }
      // Another Host (or a rebuilt one) in the meantime: its statuses are its own.
      if (!_accepts(origin)) return;
      final statuses = await _credentials(api, _current?.forms ?? const {});
      final latest = _current;
      if (statuses != null && latest != null && _accepts(origin)) _set(latest.copyWith(credentials: statuses));
      return;
    }
    final op = value == null ? SettingsOp.unset(field.path) : SettingsOp.set(field.path, value);
    final ok = await _edit(field, op);
    if (!ok) throw EngineSettingsFailure(_current?.errors[field.key] ?? appL10n.commonSaveFailed);
  }

  /// Every field of [ns] back to its default (live ones at once, the rest
  /// held). Secrets stay.
  Future<void> resetAll(String ns) async {
    final current = _current;
    final form = current?[ns];
    if (current == null || form == null) return;
    final snapshot = current.settingsFor(ns);
    final view = snapshot[ns]!;
    final paths = <List<String>>[];
    void walk(Object? user, List<String> path) {
      final node = path.isEmpty ? view.schema : schemaAt(view.schema, path);
      final grouped = node != null && node.effective.fields != null && user is Map;
      if (path.isNotEmpty && !grouped) {
        paths.add(path);
        return;
      }
      if (user is Map) {
        for (final key in user.keys) {
          walk(user[key], [...path, '$key']);
        }
      }
    }

    walk(view.user, const []);
    final live = [
      for (final p in paths)
        if (form.isLive(p)) p,
    ];
    for (final path in paths) {
      if (!form.isLive(path)) _hold(ns, SettingsOp.unset(path), FieldRef(ns, path));
    }
    if (live.isNotEmpty) {
      await _writeLive(
        ns,
        [for (final p in live) SettingsOp.unset(p)],
        fields: [for (final p in live) FieldRef(ns, p)],
      );
    }
  }

  /// Applies [ns]'s held edits together. True when they took effect.
  Future<bool> save(String ns) {
    final current = _current;
    final form = current?[ns];
    final ops = current?.draftOf(ns) ?? const <SettingsOp>[];
    if (current == null || form == null || ops.isEmpty || current.isApplying(ns)) return Future.value(false);
    return _run(ns, ops, undo: _undoOf(form.view, ops));
  }

  /// Puts back what [ns] had before a save the Host could not undo, and drops
  /// the held edits.
  Future<bool> rollback(String ns) async {
    final current = _current;
    final job = current?.jobOf(ns);
    if (current == null || job == null || job.running) return false;
    if (job.undo.isEmpty) {
      discard(ns);
      return true;
    }
    final ok = await _run(ns, job.undo, undo: const []);
    if (ok) discard(ns);
    return ok;
  }

  /// Runs a failed save again: the held edits, or what was sent when the
  /// Host kept it (nothing is held any more then). After a dropped
  /// connection the entry is read first, and nothing is sent again when the
  /// write had landed.
  Future<bool> retry(String ns) async {
    var current = _current;
    var job = current?.jobOf(ns);
    if (current == null) return false;
    if (job?.failure?.kind == PluginConfigFailureKind.unknown) {
      await refresh().catchError((Object _) {});
      current = _current;
      if (current == null) return false;
      job = current.jobOf(ns);
      if (!current.hasDraft(ns)) {
        discard(ns);
        return true;
      }
    }
    if (current.hasDraft(ns) || job == null || job.running) return save(ns);
    return _run(ns, job.ops, undo: job.undo);
  }

  /// [discard] unless a save of [ns] is running (its page was left).
  void discardIfIdle(String ns) {
    if (!ref.mounted) return;
    final current = _current;
    if (current == null || current.isApplying(ns)) return;
    if (!current.hasDraft(ns) && current.jobOf(ns) == null) return;
    discard(ns);
  }

  /// Drops [ns]'s held edits and any failed save.
  void discard(String ns) {
    final current = _current;
    if (current == null) return;
    _doneTimers.remove(ns)?.cancel();
    _set(
      current.copyWith(
        drafts: {...current.drafts}..remove(ns),
        jobs: {...current.jobs}..removeWhere((key, job) => key == ns && !job.running),
      ),
    );
  }

  Future<bool> _run(String ns, List<SettingsOp> ops, {required List<SettingsOp> undo}) async {
    final api = _api;
    final current = _current;
    if (api == null || current == null) return false;
    final origin = _origin;
    _doneTimers.remove(ns)?.cancel();
    var job = PluginConfigJob(step: PluginConfigStep.saving, ops: ops, undo: undo);
    void publish({PluginConfigForm? applied, bool clearDrafts = false, Map<String, String>? errors}) {
      final latest = _current;
      if (latest == null || !_accepts(origin)) return;
      _set(
        latest.copyWith(
          forms: applied != null ? {...latest.forms, ns: applied} : null,
          drafts: clearDrafts ? ({...latest.drafts}..remove(ns)) : null,
          jobs: {...latest.jobs, ns: job},
          errors: errors,
        ),
      );
    }

    publish();
    try {
      PluginConfigForm? applied;
      await for (final event in api.apply(ns, ops, revision: current[ns]?.revision)) {
        if (!_accepts(origin)) return false;
        switch (event) {
          case PluginConfigProgress(:final step):
            job = job.copyWith(step: step);
            publish();
          case PluginConfigApplied(:final form):
            applied = form;
        }
      }
      if (!_accepts(origin)) return false;
      // The form is read-only while a save runs: nothing else was held.
      job = job.copyWith(done: true);
      publish(applied: applied, clearDrafts: true);
      _doneTimers[ns] = Timer(doneFor, () {
        final now = _current;
        if (now == null || !_accepts(origin) || now.jobs[ns]?.done != true) return;
        _set(now.copyWith(jobs: {...now.jobs}..remove(ns)));
      });
      return true;
    } catch (error) {
      if (!_accepts(origin)) return false;
      final failure = pluginConfigFailureOf(error);
      job = job.copyWith(failure: failure);
      // The field the Host named carries the reason too.
      final latest = _current;
      publish(
        errors: failure.path == null || latest == null
            ? null
            : {...latest.errors, FieldRef(ns, failure.path!).key: failure.message},
      );
      // The Host has moved on (a conflict, a reload that changed things):
      // read it again under the held edits.
      unawaited(refresh().catchError((Object _) {}));
      return false;
    }
  }
}

final pluginConfigProvider = AsyncNotifierProvider<PluginConfigController, PluginConfigState?>(
  PluginConfigController.new,
  retry: (_, _) => null,
);

/// Writes a plugin form's fields through [PluginConfigController].
class PluginConfigEditor implements SettingsEditor {
  const PluginConfigEditor(this.controller);

  final PluginConfigController controller;

  @override
  void clearError(FieldRef field) => controller.clearError(field);

  @override
  Future<bool> set(FieldRef field, Object? value, {Object? fallback}) =>
      controller.set(field, value, fallback: fallback);

  @override
  Future<bool> reset(FieldRef field) => controller.reset(field);

  @override
  Future<void> setSecret(FieldRef field, String value) => controller.setSecret(field, value);

  @override
  Future<void> clearSecret(FieldRef field) => controller.clearSecret(field);
}
