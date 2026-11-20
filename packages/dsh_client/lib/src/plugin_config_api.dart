/// A plugin entry's complete configuration through the dsh-go bridge
/// (PLUGIN-CONFIG-CONTRACT R1 §4, docs/design/plugin-config.md):
///
/// * `GET  /dsh-go/v1/plugin-config`: the profile's entries, each with
///   whether its complete Config can be edited (and why not);
/// * `GET  /dsh-go/v1/plugin-config/<entryId>`: one entry's schemastery
///   schema (`{uid, refs}`, live nodes keep `meta.volatile`), its redacted
///   layers, secret facts and an opaque revision;
/// * `POST /dsh-go/v1/plugin-config/<entryId>`: `{revision, ops}` with the
///   `set` / `unset` path edits of `settings/mutate`, ordinary fields
///   included; answered once the Host reconciled, with the new entry.
///
/// Refusals are an HTTP status plus a stable code: 400 `invalid-operation`,
/// 404 `entry-unavailable`, 409 `conflict` / `overridden` / `apply-failed`
/// (the previous configuration was restored), 422 `invalid-config`, 503
/// `host-unavailable`, 500 `recovery-failed` (it could not be). A 404 of the
/// list itself means the Host has no such routes. Secrets never cross: bound
/// ones go through `credentials/*`.
library;

import 'carrier.dart';
import 'connection.dart';
import 'dsh_go_api.dart';
import 'engine_settings_api.dart';
import 'errors.dart';
import 'features_api.dart';
import 'json.dart';
import 'plugins_api.dart';
import 'session_api.dart';

const dshGoPluginConfigPath = '/dsh-go/v1/plugin-config';

/// One entry's route: the profile id, percent-encoded as one segment.
String dshGoPluginConfigEntryPath(String entryId) => '$dshGoPluginConfigPath/${Uri.encodeComponent(entryId)}';

/// One entry of `GET /dsh-go/v1/plugin-config`.
///
/// Bridge R7 (runtime r14) also says who carries the entry and whether a
/// write would be taken ([owner], [bundle], [kind], [source], [writable]),
/// and labels it with the declaring bundle's title. An older bridge sends
/// none of these (null here) and labels an entry with its id.
class PluginConfigEntrySummary {
  const PluginConfigEntrySummary({
    required this.entryId,
    this.package,
    this.label,
    this.state = 'active',
    this.configurable = false,
    this.reason,
    this.owner,
    this.bundle,
    this.kind,
    this.source,
    this.writable,
  });

  static PluginConfigEntrySummary? fromJson(Object? json) {
    final map = asMap(json);
    final entryId = asString(map?['entryId']);
    if (map == null || entryId == null || entryId.isEmpty) return null;
    return PluginConfigEntrySummary(
      entryId: entryId,
      package: asString(map['package']),
      label: LocalizedText.fromJson(map['label']),
      state: asString(map['state']) ?? 'active',
      configurable: map['configurable'] == true,
      reason: asString(map['reason']),
      owner: asString(map['owner']),
      bundle: asString(map['bundle']),
      kind: asString(map['kind']),
      source: asString(map['source']),
      writable: switch (map['writable']) {
        final bool writable => writable,
        _ => null,
      },
    );
  }

  /// The profile id: the only write target.
  final String entryId;
  final String? package;

  /// R7: the declaring bundle's `meta.title` (a string or `{en, zh}`), else
  /// the entry id. An older bridge: the entry id.
  final LocalizedText? label;

  /// `active`, `inactive`, `failed`, `unsupported`.
  final String state;

  /// Its complete Config can be read and edited.
  final bool configurable;

  /// Why not: `no-schema`, `not-active`, `ambiguous-id`, `nested-include`,
  /// `unsupported-schema`; R7 also `entry-unavailable` (not a plugin's).
  /// R7 on a configurable entry that is not [writable]: `overridden` (a host
  /// or command-line overlay sets its whole config) or `host-unavailable`.
  final String? reason;

  /// R7: `core` (the installation's own layers), `optional` (an official
  /// optional bundle), `installed` (a package the profile installed) or
  /// `overlay` (no single enabled bundle is proven to declare it: home and
  /// command-line patches, the App's own rows). A description, not a grant.
  final String? owner;

  /// R7: the enabled bundle declaring the entry; null when none is proven.
  final String? bundle;

  /// R7: `plugin`, `core` or `overlay`.
  final String? kind;

  /// R7: `official-optional-bundle`, `installed-bundle` or `unverified`.
  final String? source;

  /// R7: a write would be taken. False on an entry that is not configurable
  /// and on a configurable one an overlay covers. Null from an older bridge,
  /// which only says so once the entry is read.
  final bool? writable;
}

/// A secret position of an entry: whether it holds a value and how it can be
/// written (never the value).
class PluginConfigSecretFact {
  const PluginConfigSecretFact(this.path, {this.configured = false, this.credentialRef, this.writable = false});

  static PluginConfigSecretFact? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final path = asStringList(map['path']);
    if (path.isEmpty) return null;
    final ref = asString(map['credentialRef']) ?? asString(map['ref']) ?? asString(asMap(map['binding'])?['ref']);
    final writable = map['writable'];
    return PluginConfigSecretFact(
      path,
      configured: map['configured'] == true || map['set'] == true,
      credentialRef: ref,
      // A bare secret (no credential binding) is not written in v1.
      writable: writable is bool ? writable && ref != null : ref != null,
    );
  }

  final List<String> path;
  final bool configured;

  /// The credential it is bound to (`credentials/set` writes it).
  final String? credentialRef;
  final bool writable;
}

/// `GET /dsh-go/v1/plugin-config/<entryId>` (and a successful write's answer).
class PluginConfigEntryDetail {
  const PluginConfigEntryDetail({
    required this.entryId,
    required this.revision,
    required this.schema,
    this.value = const {},
    this.base,
    this.user,
    this.secrets = const [],
    this.writable = true,
  });

  static PluginConfigEntryDetail? fromJson(Object? json) {
    var map = asMap(json);
    if (map != null && map['entryId'] == null && asMap(map['entry']) != null) map = asMap(map['entry']);
    if (map == null || map['v'] != 1) return null;
    final entryId = asString(map['entryId']);
    final revision = map['revision'];
    if (entryId == null || entryId.isEmpty || revision is! String || asMap(map['schema']) == null) return null;
    return PluginConfigEntryDetail(
      entryId: entryId,
      revision: revision,
      schema: SchemaNode.fromJson(map['schema']),
      value: asMapOrEmpty(map['value']),
      base: asMap(map['base']),
      user: asMap(map['user']),
      secrets: [for (final s in asListOrEmpty(map['secrets'])) ?PluginConfigSecretFact.fromJson(s)],
      writable: map['writable'] == true,
    );
  }

  final String entryId;

  /// Opaque: sent back as is with the next write.
  final String revision;
  final SchemaNode schema;
  final Map<String, Object?> value;
  final Map<String, Object?>? base;
  final Map<String, Object?>? user;
  final List<PluginConfigSecretFact> secrets;
  final bool writable;

  /// The same entry as the settings forms read one.
  SettingsNamespaceView get view => SettingsNamespaceView(
    ns: entryId,
    schema: schema,
    value: value,
    base: base,
    user: user,
    revision: 0,
    secrets: [for (final s in secrets) SettingsSecretSlot(s.path, set: s.configured)],
    writable: writable,
  );
}

extension PluginConfigBridgeApi on DshClient {
  DshConnection get _bridge => (carrier as DshHttpCarrier).connection;

  /// `GET /dsh-go/v1/plugin-config`. Null when the Host has no such routes
  /// (404: no bridge, or an older one) or this carrier cannot reach the
  /// bridge (the relay). Throws [DshRemoteException] `plugin-config/<code>`.
  Future<List<PluginConfigEntrySummary>?> listPluginConfig({Duration timeout = const Duration(seconds: 10)}) async {
    if (!canReachDshGo) return null;
    final response = await _bridge.get(dshGoPluginConfigPath, timeout: timeout);
    if (response.statusCode == 404 && _codeOf(response) == null) return null;
    if (response.statusCode != 200) throw pluginConfigHttpError(dshGoPluginConfigPath, response);
    final json = tryDecodeJson(response.text);
    final list = json is List ? json : asMap(json)?['entries'];
    if (list is! List) throw const DshProtocolException('$dshGoPluginConfigPath: not an entry list');
    return [for (final e in list) ?PluginConfigEntrySummary.fromJson(e)];
  }

  /// `GET /dsh-go/v1/plugin-config/<entryId>`.
  Future<PluginConfigEntryDetail> readPluginConfig(
    String entryId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final path = dshGoPluginConfigEntryPath(entryId);
    final response = await _bridge.get(path, timeout: timeout);
    return _detail(path, response);
  }

  /// `POST /dsh-go/v1/plugin-config/<entryId>` with [revision] as read.
  /// Answers once the Host has reconciled; a timeout leaves the outcome
  /// unknown (read the entry again before writing again).
  Future<PluginConfigEntryDetail> writePluginConfig(
    String entryId, {
    required String revision,
    required List<SettingsOp> ops,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final path = dshGoPluginConfigEntryPath(entryId);
    final response = await _bridge.postJson(path, {
      'revision': revision,
      'ops': [for (final op in ops) op.toJson()],
    }, timeout: timeout);
    return _detail(path, response);
  }

  PluginConfigEntryDetail _detail(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw pluginConfigHttpError(path, response);
    final detail = PluginConfigEntryDetail.fromJson(tryDecodeJson(response.text));
    if (detail == null) throw DshProtocolException('$path: not a plugin-config entry');
    return detail;
  }
}

Map<String, Object?>? _errorOf(DshHttpResponse response) {
  final body = asMap(tryDecodeJson(response.text));
  return asMap(body?['error']) ?? body;
}

String? _codeOf(DshHttpResponse response) => asString(_errorOf(response)?['code']);

/// A refusal as `plugin-config/<code>` (`plugin-config/http-<status>` without
/// one); `details` carry the status and the field `path` when given.
DshRemoteException pluginConfigHttpError(String path, DshHttpResponse response) {
  final error = _errorOf(response);
  final code = asString(error?['code']);
  final field = asStringList(error?['path']);
  return DshRemoteException(
    code == null ? 'plugin-config/http-${response.statusCode}' : 'plugin-config/$code',
    asString(error?['message']) ?? '$path: HTTP ${response.statusCode}',
    {'route': path, 'status': response.statusCode, if (field.isNotEmpty) 'path': field},
  );
}
