// The plugin configuration through the dsh-go bridge (PLUGIN-CONFIG-CONTRACT
// R1 §4–§6): the profile's entries from `GET /dsh-go/v1/plugin-config`, one
// entry's complete form from `GET …/<entryId>`, writes as `{revision, ops}`
// to `POST …/<entryId>`, secrets bound to a credential through
// `credentials/*` (a bare secret is not written here).
//
// Capability: a Host without those routes (no bridge, an older one: 404) or a
// connection that cannot reach the bridge (the relay) gets [fallback] — the
// live fields `settings/describe` serves — exactly as before. Asked again
// once the Host restarts.
//
// Scope: only a plugin's entry is read or written ([PluginConfigScope]). The
// Host lists DSH's whole profile, core included; bridge R7 refuses what is
// not a plugin's itself, an older one would take a write to any of it. An
// entry out of scope — by the confirmed plugin list or by the Host's own
// `owner` — fails here, before a request goes out, whatever the list or the
// page asked for. A credential is described, set or cleared only when a
// plugin entry in scope declares it, in a form read here.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../engine_settings_state.dart' show FieldRef;
import 'plugin_config_api.dart';
import 'plugin_config_scope.dart';

class BridgePluginConfigApi implements PluginConfigApi {
  BridgePluginConfigApi(
    this.client,
    this.fallback, {
    required this.scope,
    this.readTimeout = const Duration(seconds: 10),
    this.writeTimeout = const Duration(seconds: 60),
  });

  final DshClient client;

  /// The plugins as the plugin manager lists them now (asked at each call).
  final PluginConfigScope Function() scope;

  /// What a Host without the routes serves.
  final PluginConfigApi fallback;
  final Duration readTimeout;

  /// How long a write may take to reconcile; past it the outcome is unknown.
  final Duration writeTimeout;

  /// Whether the Host has the routes: null until asked.
  bool? _supported;

  /// Each entry as the Host listed it last: its package, and from bridge R7
  /// its owner, bundle and kind.
  final Map<String, PluginConfigEntry> _listed = {};

  /// The credentials each entry's form declared, as last read here.
  final Map<String, Set<String>> _credentialRefs = {};

  /// [ns] is a plugin's entry: else nothing is asked or sent for it.
  void _ensureInScope(String ns) {
    final current = scope();
    if (!current.admits(ns, _listed[ns])) throw current.refusal();
  }

  /// The credentials plugin entries in scope declare.
  Set<String> _credentialsInScope(PluginConfigScope current) => {
    for (final MapEntry(:key, :value) in _credentialRefs.entries)
      if (current.admits(key, _listed[key])) ...value,
  };

  /// [ref] is a credential a plugin entry in scope declares: else it is not
  /// written.
  void _ensureCredentialInScope(String ref) {
    final current = scope();
    if (!_credentialsInScope(current).contains(ref)) throw current.refusal();
  }

  bool? get supported => _supported;

  /// Ask the Host again (it restarted, the bridge may have changed).
  void forget() => _supported = null;

  bool get _bridge => _supported == true;

  @override
  Stream<void> get changes => fallback.changes;

  @override
  Future<PluginConfigCatalog?> describe() async {
    if (_supported == false) return fallback.describe();
    final List<PluginConfigEntrySummary>? listed;
    try {
      listed = await client.listPluginConfig(timeout: readTimeout);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
    if (listed == null) {
      _supported = false;
      return fallback.describe();
    }
    _supported = true;
    final entries = {for (final e in listed) e.entryId: PluginConfigEntry.listed(e)};
    _listed
      ..clear()
      ..addAll(entries);
    return PluginConfigCatalog(forms: const {}, lazy: true, complete: true, entries: entries);
  }

  @override
  Future<PluginConfigForm?> read(String ns) async {
    _ensureInScope(ns);
    if (!_bridge) return fallback.read(ns);
    try {
      return _form(await client.readPluginConfig(ns, timeout: readTimeout));
    } on DshRemoteException catch (error) {
      if (error.code == 'plugin-config/entry-unavailable') {
        _credentialRefs.remove(ns);
        return null;
      }
      throw pluginConfigFailureOf(error);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
  }

  PluginConfigForm _form(PluginConfigEntryDetail detail) {
    final form = PluginConfigForm(
      detail.view,
      revision: detail.revision,
      secretBindings: {
        for (final secret in detail.secrets) FieldRef(detail.entryId, secret.path).key: secret.credentialRef,
      },
    );
    _credentialRefs[detail.entryId] = form.credentialRefs;
    return form;
  }

  @override
  Stream<PluginConfigEvent> apply(String ns, List<SettingsOp> ops, {Object? revision}) async* {
    _ensureInScope(ns);
    if (!_bridge) {
      yield* fallback.apply(ns, ops, revision: revision);
      return;
    }
    // No progress protocol: submitted, then applied or failed (§4.3).
    yield const PluginConfigProgress(PluginConfigStep.saving);
    // The plugin list may have changed while the step was shown.
    _ensureInScope(ns);
    final PluginConfigEntryDetail detail;
    try {
      detail = await client.writePluginConfig(ns, revision: '$revision', ops: ops, timeout: writeTimeout);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
    yield PluginConfigApplied(_form(detail), reloaded: true);
  }

  @override
  Future<Map<String, CredentialStatus>> describeCredentials(Set<String> refs) async {
    if (!_bridge) return fallback.describeCredentials(refs);
    final asked = refs.intersection(_credentialsInScope(scope()));
    if (asked.isEmpty) return const {};
    return client.describeCredentials(asked.toList());
  }

  @override
  Future<void> setCredential(String ref, String value) async {
    if (!_bridge) return fallback.setCredential(ref, value);
    _ensureCredentialInScope(ref);
    try {
      await client.setProviderKey(value, ref: ref);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
  }

  @override
  Future<void> clearCredential(String ref) async {
    if (!_bridge) return fallback.clearCredential(ref);
    _ensureCredentialInScope(ref);
    try {
      await client.clearProviderKey(ref: ref);
    } catch (error) {
      throw pluginConfigFailureOf(error);
    }
  }
}
