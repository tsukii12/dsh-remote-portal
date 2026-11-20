/// Plugin management (`pluginManager/*`) and plugin market index format 1.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-plugin-manager`,
/// `@deepseek-ai/dsh-plugin-market-index`). The manager is the only write
/// path: install, remove, enable and disable go through it on every host.
/// Market indexes are third-party JSON documents read by the app itself;
/// [parseMarketIndex] follows the official validator but skips bad entries
/// instead of rejecting the whole index.
library;

import 'dart:convert';

import 'background_session_read.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Localized text
// -----------------------------------------------------------------------------

/// A plain string or a map of language id to text (`{en, zh, ...}`).
class LocalizedText {
  const LocalizedText(this.values);

  /// Text without language information (stored under the empty key).
  LocalizedText.plain(String text) : values = {'': text};

  /// Lenient reader: a non-blank string, or a map whose non-blank string
  /// members are kept. `null` when nothing usable remains.
  static LocalizedText? fromJson(Object? json) {
    if (json is String) return json.trim().isEmpty ? null : LocalizedText.plain(json);
    final map = asMap(json);
    if (map == null) return null;
    final values = <String, String>{};
    for (final MapEntry(:key, :value) in map.entries) {
      if (value is String && value.trim().isNotEmpty) values[_tag(key)] = value;
    }
    return values.isEmpty ? null : LocalizedText(values);
  }

  /// `zh_CN` → `zh-cn`: plugins spell language ids both ways (schemastery
  /// takes whatever keys `.i18n()` is given).
  static String _tag(String id) => id.toLowerCase().replaceAll('_', '-');

  static final _han = RegExp(r'[\u3400-\u9fff]');

  /// Language id (lowercase, `zh`, `zh-cn`, ...) or `''` for plain text.
  final Map<String, String> values;

  /// Best text for [locale]: exact id, then its language, then any variant
  /// of that language, then plain text written in it, then English (`en`,
  /// then any variant), then plain text, then the first value.
  ///
  /// Plain text is what `.description()` gave before `.i18n()` added
  /// languages (schemastery keeps it under `''`): a Chinese plugin that only
  /// translated into English must still read in Chinese for a Chinese UI.
  String resolve([String locale = 'zh']) {
    final tagged = {for (final MapEntry(:key, :value) in values.entries) _tag(key): value};
    final wanted = _tag(locale);
    final language = wanted.split('-').first;
    String? of(String language) =>
        tagged[language] ?? tagged.entries.where((e) => e.key.startsWith('$language-')).map((e) => e.value).firstOrNull;
    final plain = tagged[''];
    // Chinese is told apart by its characters; anything else counts as the
    // other UI language.
    final plainMatches = plain != null && _han.hasMatch(plain) == (language == 'zh');
    return tagged[wanted] ?? of(language) ?? (plainMatches ? plain : null) ?? of('en') ?? plain ?? values.values.first;
  }

  /// Every variant, for search.
  Iterable<String> get all => values.values;

  Object toJson() => values.length == 1 && values.containsKey('') ? values['']! : values;

  @override
  String toString() => resolve();
}

// -----------------------------------------------------------------------------
// pluginManager results
// -----------------------------------------------------------------------------

/// Display metadata of a bundle or a row (`meta`).
class PluginDisplayMeta {
  const PluginDisplayMeta({this.title, this.description, this.icon, this.error});

  static PluginDisplayMeta? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return PluginDisplayMeta(
      title: LocalizedText.fromJson(map['title']),
      description: LocalizedText.fromJson(map['description']),
      icon: asString(map['icon']),
      error: asString(map['error']),
    );
  }

  final LocalizedText? title;
  final LocalizedText? description;

  /// Base64 image `data:` URL (render as an image, never as markup).
  final String? icon;

  /// Local metadata diagnostic; the plugin stays manageable.
  final String? error;
}

/// A package the running DSH version rejects (`incompatible-version`).
class PluginIncompatibility {
  const PluginIncompatibility({
    required this.name,
    required this.version,
    required this.runtimeVersion,
    this.requirements = const {},
  });

  factory PluginIncompatibility.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginIncompatibility(
      name: asString(map['name']) ?? '',
      version: asString(map['version']) ?? '',
      runtimeVersion: asString(map['runtimeVersion']) ?? '',
      requirements: {
        for (final MapEntry(:key, :value) in asMapOrEmpty(map['requirements']).entries)
          if (value is String) key: value,
      },
    );
  }

  final String name;
  final String version;
  final String runtimeVersion;

  /// Unmet requirements keyed `engines.dsh` or by DSH peer package name.
  final Map<String, String> requirements;
}

/// `error` of a management result or a listed bundle.
class PluginManagerError {
  const PluginManagerError(this.code, {this.diagnostic, this.incompatible = const []});

  static PluginManagerError? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return PluginManagerError(
      asString(map['code']) ?? 'unknown',
      diagnostic: asString(map['diagnostic']),
      incompatible: asListOrEmpty(map['incompatible']).map(PluginIncompatibility.fromJson).toList(growable: false),
    );
  }

  /// `management-required`, `unaddressable`, `unknown-plugin`,
  /// `invalid-spec`, `already-installed`, `ambiguous-install`, `not-bundle`,
  /// `not-removable`, `stop-profile`, `bundle-in-use`, `stale-approval`,
  /// `incompatible-version`, `operation-error`.
  final String code;
  final String? diagnostic;
  final List<PluginIncompatibility> incompatible;
}

/// One row a bundle's patch inserts.
class PluginBundleRow {
  const PluginBundleRow({required this.rowId, required this.moduleName, this.meta, this.entryId});

  factory PluginBundleRow.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginBundleRow(
      rowId: asString(map['rowId']) ?? '',
      moduleName: asString(map['moduleName']) ?? '',
      meta: PluginDisplayMeta.fromJson(map['meta']),
      entryId: asString(map['entryId']),
    );
  }

  final String rowId;
  final String moduleName;
  final PluginDisplayMeta? meta;

  /// Loader entry carrying this row (for [PluginsApi.setPluginEnabled]).
  final String? entryId;
}

/// One `pluginManager/listBundles` item.
class PluginBundle {
  const PluginBundle({
    required this.name,
    this.official = false,
    this.availability = 'profile',
    this.installTargetSpec,
    this.installTargetVersion,
    this.version,
    this.meta,
    this.description,
    this.enabled = false,
    this.installed = false,
    this.source,
    this.optional = false,
    this.removable = false,
    this.readOnlyReason,
    this.error,
    this.rows = const [],
    this.overrides = const [],
  });

  factory PluginBundle.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final target = asMap(map['installTarget']);
    return PluginBundle(
      name: asString(map['name']) ?? '',
      official: map['official'] == true,
      availability: asString(map['availability']) ?? 'profile',
      installTargetSpec: asString(target?['spec']),
      installTargetVersion: asString(target?['version']),
      version: asString(map['version']),
      meta: PluginDisplayMeta.fromJson(map['meta']),
      description: asString(map['description']),
      enabled: map['enabled'] == true,
      installed: map['installed'] == true,
      source: asString(map['source']),
      optional: map['optional'] == true,
      removable: map['removable'] == true,
      readOnlyReason: asString(map['readOnlyReason']),
      error: PluginManagerError.fromJson(map['error']),
      rows: asListOrEmpty(map['rows']).map(PluginBundleRow.fromJson).toList(growable: false),
      overrides: asStringList(map['overrides']),
    );
  }

  final String name;

  /// Project-maintained optional bundle or on-demand catalog entry.
  final bool official;

  /// `profile`, `installation` or `missing`.
  final String availability;

  /// Exact target offered for an on-demand official entry (not installed yet).
  final String? installTargetSpec;
  final String? installTargetVersion;
  final String? version;
  final PluginDisplayMeta? meta;

  /// Untranslated `package.json` description.
  final String? description;

  /// Selected in the profile manifest (a load error may still skip it).
  final bool enabled;

  /// The profile declares this dependency.
  final bool installed;

  /// `pnpm add` spec of a profile dependency.
  final String? source;

  /// Shipped with the installation for the person to switch on; never removable.
  final bool optional;
  final bool removable;

  /// `management-required` or `unaddressable`: switches are not available.
  final String? readOnlyReason;
  final PluginManagerError? error;
  final List<PluginBundleRow> rows;
  final List<String> overrides;

  bool get isOnDemand => official && !installed && availability == 'missing' && installTargetSpec != null;

  String title([String locale = 'zh']) => meta?.title?.resolve(locale) ?? name;

  String? summary([String locale = 'zh']) => meta?.description?.resolve(locale) ?? description;
}

/// One `pluginManager/listPlugins` entry.
class PluginEntry {
  const PluginEntry({
    required this.entryId,
    required this.moduleName,
    this.meta,
    this.enabled = false,
    this.fiberPhase,
    this.patchId,
    this.readOnlyReason,
  });

  factory PluginEntry.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginEntry(
      entryId: asString(map['entryId']) ?? '',
      moduleName: asString(map['moduleName']) ?? '',
      meta: PluginDisplayMeta.fromJson(map['meta']),
      enabled: map['enabled'] == true,
      fiberPhase: asString(map['fiberPhase']),
      patchId: asString(map['patchId']),
      readOnlyReason: asString(map['readOnlyReason']),
    );
  }

  final String entryId;
  final String moduleName;
  final PluginDisplayMeta? meta;
  final bool enabled;

  /// `failed`, `pending`, `active`, `loading`, `unloading` or null.
  final String? fiberPhase;
  final String? patchId;
  final String? readOnlyReason;
}

/// How a management operation took effect.
enum PluginApplication {
  applied('applied'),
  restartRequired('restart-required'),
  failed('failed'),
  cancelled('cancelled'),
  overridden('overridden'),
  unknown('');

  const PluginApplication(this.wire);
  final String wire;

  static PluginApplication parse(Object? value) =>
      values.firstWhere((v) => v.wire == value && v != unknown, orElse: () => unknown);
}

/// The last pnpm run of an operation (`packageResult`).
class PluginPackageRun {
  const PluginPackageRun({
    this.exitCode,
    this.output = '',
    this.truncated = false,
    this.logPath,
    this.kind,
    this.timedOut = false,
    this.incompatible = const [],
  });

  static PluginPackageRun? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return PluginPackageRun(
      exitCode: asInt(map['exitCode']),
      output: asString(map['output']) ?? '',
      truncated: map['truncated'] == true,
      logPath: asString(map['logPath']),
      kind: asString(map['kind']),
      timedOut: map['timedOut'] == true,
      incompatible: asListOrEmpty(map['incompatible']).map(PluginIncompatibility.fromJson).toList(growable: false),
    );
  }

  final int? exitCode;
  final String output;
  final bool truncated;
  final String? logPath;

  /// Present when the run failed: `network`, `timeout`, `integrity`,
  /// `pnpm-missing`, `not-found`, `no-matching-version`, `disk-full`,
  /// `permission`, `build-blocked`, `unknown`.
  final String? kind;
  final bool timedOut;
  final List<PluginIncompatibility> incompatible;
}

/// Result of install / remove / enable operations.
class PluginOperationResult {
  const PluginOperationResult({
    this.changed = false,
    required this.application,
    this.restartReason,
    this.stage,
    this.target = '',
    this.enabled,
    this.error,
    this.warnings = const [],
    this.packageResult,
    this.bundle,
    this.version,
    this.pendingBuilds = const [],
    this.approvedBuilds = const [],
    this.registries = const [],
    this.failedAt,
  });

  factory PluginOperationResult.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginOperationResult(
      changed: map['changed'] == true,
      application: PluginApplication.parse(map['application']),
      restartReason: asString(map['restartReason']),
      stage: asString(map['stage']),
      target: asString(map['target']) ?? '',
      enabled: asBool(map['enabled']),
      error: PluginManagerError.fromJson(map['error']),
      warnings: asStringList(map['warnings']),
      packageResult: PluginPackageRun.fromJson(map['packageResult']),
      bundle: asString(map['bundle']),
      version: asString(map['version']),
      pendingBuilds: asStringList(map['pendingBuilds']),
      approvedBuilds: asStringList(map['approvedBuilds']),
      registries: asListOrEmpty(map['registries']).map(asString).toList(growable: false),
      failedAt: asString(map['failedAt']),
    );
  }

  final bool changed;
  final PluginApplication application;

  /// With `restart-required`: `no-hmr`, `package-moved`, `host-module`,
  /// `unmanaged-plugin`, `module-comparison`.
  final String? restartReason;

  /// `remove`, `install` or `enable`.
  final String? stage;
  final String target;
  final bool? enabled;
  final PluginManagerError? error;
  final List<String> warnings;
  final PluginPackageRun? packageResult;

  /// Bundle an installation added.
  final String? bundle;

  /// Installed manifest version (may lag the newest release because of
  /// pnpm's `minimumReleaseAge`).
  final String? version;

  /// Packages whose build scripts pnpm blocked; retry with `approvedBuilds`.
  final List<String> pendingBuilds;
  final List<String> approvedBuilds;

  /// Registries asked, in order (`null` = pnpm's own configuration).
  final List<String?> registries;

  /// `registry` or `spec-host`: what the last failed run could not reach.
  final String? failedAt;

  bool get succeeded =>
      application == PluginApplication.applied ||
      application == PluginApplication.restartRequired ||
      application == PluginApplication.overridden;

  bool get needsRestart => application == PluginApplication.restartRequired;

  /// `packageResult.kind` of a failed run.
  String? get failureKind => packageResult?.kind;
}

/// `pluginManager/inspect`: what a spec names, before installing it.
sealed class PluginInspection {
  const PluginInspection();

  factory PluginInspection.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    if (map['status'] == 'refused') {
      return PluginInspectionRefused(
        problem: asString(map['problem']) ?? 'unknown',
        reason: asString(map['reason']) ?? '',
        registries: asListOrEmpty(map['registries']).map(asString).toList(growable: false),
      );
    }
    return PluginInspectionAccepted(
      kind: asString(map['kind']) ?? 'registry',
      name: asString(map['name']),
      version: asString(map['version']),
      description: asString(map['description']),
      bundle: asBool(map['bundle']),
      registry: asString(map['registry']),
      host: asString(map['host']),
    );
  }
}

final class PluginInspectionAccepted extends PluginInspection {
  const PluginInspectionAccepted({
    required this.kind,
    this.name,
    this.version,
    this.description,
    this.bundle,
    this.registry,
    this.host,
  });

  /// `registry`, `path`, `git` or `tarball`.
  final String kind;
  final String? name;
  final String? version;
  final String? description;

  /// Declares a bundle patch; null when the spec's form does not say.
  final bool? bundle;

  /// Registry that answered (null = pnpm's own configuration).
  final String? registry;
  final String? host;
}

final class PluginInspectionRefused extends PluginInspection {
  const PluginInspectionRefused({required this.problem, required this.reason, this.registries = const []});

  /// `network`, `unknown`, `invalid-spec`, `already-installed`, `not-found`,
  /// `not-a-package`, `not-a-bundle`.
  final String problem;
  final String reason;
  final List<String?> registries;
}

enum PluginCancelStatus { cancelled, notRunning, tooLate }

/// `pluginManager/registries`.
class PluginRegistries {
  const PluginRegistries({this.registry, this.fallbackRegistries = const [], this.resolved});

  factory PluginRegistries.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginRegistries(
      registry: asString(map['registry']),
      fallbackRegistries: asStringList(map['fallbackRegistries']),
      resolved: asString(map['resolved']),
    );
  }

  final String? registry;
  final List<String> fallbackRegistries;
  final String? resolved;
}

// -----------------------------------------------------------------------------
// plugin-manager/* host events
// -----------------------------------------------------------------------------

/// `plugin-manager/*` items of the `$events` stream (forwarded by the Host).
sealed class PluginManagerEvent {
  const PluginManagerEvent();

  /// Maps a [HostEvent]; `null` for anything that is not `plugin-manager/*`.
  static PluginManagerEvent? fromHostEvent(HostEvent event) {
    if (event is! UnknownHostEvent || !event.event.startsWith('plugin-manager/')) return null;
    final args = asListOrEmpty(event.raw['args']);
    final payload = asMapOrEmpty(args.isEmpty ? null : args.first);
    switch (event.event) {
      case 'plugin-manager/install-state':
        final attempt = asMap(payload['attempt']);
        return PluginInstallStateEvent(
          requestId: asString(payload['requestId']) ?? '',
          phase: asString(payload['phase']) ?? '',
          registry: asString(attempt?['registry']),
          attemptIndex: asInt(attempt?['index']),
          attemptTotal: asInt(attempt?['total']),
        );
      case 'plugin-manager/install-log':
        return PluginInstallLogEvent(
          requestId: asString(payload['requestId']),
          jobId: asString(payload['jobId']) ?? '',
          argv: asStringList(payload['argv']),
          stream: asString(payload['stream']) ?? 'stdout',
          text: asString(payload['text']) ?? '',
          exitCode: asInt(payload['exitCode']),
          finished: payload.containsKey('exitCode'),
        );
      case 'plugin-manager/changed':
        return PluginManagerChangedEvent(asString(payload['reason']));
      default:
        return PluginManagerOtherEvent(event.event, args);
    }
  }
}

/// `installing` (once per registry asked), `cancelling` or `applying`.
final class PluginInstallStateEvent extends PluginManagerEvent {
  const PluginInstallStateEvent({
    required this.requestId,
    required this.phase,
    this.registry,
    this.attemptIndex,
    this.attemptTotal,
  });

  final String requestId;
  final String phase;

  /// Registry of this attempt (`null` = pnpm's own configuration).
  final String? registry;
  final int? attemptIndex;
  final int? attemptTotal;
}

/// One chunk of pnpm output; [finished] marks the run's last chunk.
final class PluginInstallLogEvent extends PluginManagerEvent {
  const PluginInstallLogEvent({
    this.requestId,
    required this.jobId,
    this.argv = const [],
    this.stream = 'stdout',
    this.text = '',
    this.exitCode,
    this.finished = false,
  });

  /// Absent for runs without a request id (removals).
  final String? requestId;
  final String jobId;
  final List<String> argv;
  final String stream;
  final String text;
  final int? exitCode;
  final bool finished;
}

/// Some management operation completed (`install`, `remove`, `bundle`, ...).
final class PluginManagerChangedEvent extends PluginManagerEvent {
  const PluginManagerChangedEvent(this.reason);
  final String? reason;
}

final class PluginManagerOtherEvent extends PluginManagerEvent {
  const PluginManagerOtherEvent(this.event, this.args);
  final String event;
  final List<Object?> args;
}

// -----------------------------------------------------------------------------
// Client wrappers
// -----------------------------------------------------------------------------

/// `pluginManager/*` on [DshClient].
///
/// Over the ds-harness-remote relay only the list and enable endpoints are
/// allowed; check [canInstallPlugins] before offering installs.
extension PluginsApi on DshClient {
  /// Whether this carrier lets install/remove calls through.
  bool get canInstallPlugins =>
      supportsEndpoint('pluginManager/installBundle') && supportsEndpoint('pluginManager/removeBundle');

  /// `plugin-manager/*` host events (install progress, changes).
  Stream<PluginManagerEvent> get pluginManagerEvents =>
      hostEvents.map(PluginManagerEvent.fromHostEvent).where((e) => e != null).cast<PluginManagerEvent>();

  Future<List<PluginBundle>> listBundles() async {
    final read = tryBackgroundListRead(BackgroundListKind.bundles);
    if (read != null) return (await read) as List<PluginBundle>;
    return asListOrEmpty(await rpc.call('pluginManager/listBundles'))
        .map(PluginBundle.fromJson)
        .toList(growable: false);
  }

  Future<List<PluginEntry>> listPlugins() async {
    final read = tryBackgroundListRead(BackgroundListKind.plugins);
    if (read != null) return (await read) as List<PluginEntry>;
    return asListOrEmpty(await rpc.call('pluginManager/listPlugins')).map(PluginEntry.fromJson).toList(growable: false);
  }

  /// Selects or deselects a bundle layer; installed files stay.
  Future<PluginOperationResult> setBundleEnabled(String name, bool enabled) async => PluginOperationResult.fromJson(
    await rpc.call('pluginManager/setBundleEnabled', {'name': name, 'enabled': enabled}),
  );

  /// Enables or disables one Loader entry ([PluginEntry.entryId]).
  Future<PluginOperationResult> setPluginEnabled(String entryId, bool enabled) async => PluginOperationResult.fromJson(
    await rpc.call('pluginManager/setPluginEnabled', {'id': entryId, 'enabled': enabled}),
  );

  /// `pluginManager/inspect`: reads what [spec] names (registry asked first:
  /// [registry]; absent, the configured one).
  Future<PluginInspection> inspectPlugin(String spec, {String? registry}) async => PluginInspection.fromJson(
    await rpc.call('pluginManager/inspect', {
      'spec': spec,
      if (registry != null) 'options': {'registry': registry},
    }),
  );

  /// `pluginManager/installBundle`. Resolves only after the whole run (pnpm
  /// plus activation), so the call gets a long [timeout]; pass a
  /// [requestId] to follow [pluginManagerEvents], [cancelInstall] or
  /// recover with [waitForInstall] after a lost response.
  Future<PluginOperationResult> installBundle(
    String spec, {
    String? requestId,
    bool? enabled,
    bool? saveExact,
    List<String>? approvedBuilds,
    String? registry,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final options = <String, Object?>{
      'enabled': ?enabled,
      'saveExact': ?saveExact,
      'requestId': ?requestId,
      'approvedBuilds': ?approvedBuilds,
      'registry': ?registry,
    };
    final value = await rpc.call('pluginManager/installBundle', {
      'spec': spec,
      if (options.isNotEmpty) 'options': options,
    }, timeout);
    return PluginOperationResult.fromJson(value);
  }

  /// Stops an installation; `cancelled` once its files are restored.
  Future<PluginCancelStatus> cancelInstall(String requestId) async {
    final value = asMapOrEmpty(
      await rpc.call('pluginManager/cancelInstall', {'requestId': requestId}, const Duration(minutes: 5)),
    );
    return switch (value['status']) {
      'cancelled' => PluginCancelStatus.cancelled,
      'too-late' => PluginCancelStatus.tooLate,
      _ => PluginCancelStatus.notRunning,
    };
  }

  /// Waits for an active installation's result; `null` when no installation
  /// with [requestId] is running (that says nothing about how it ended).
  Future<PluginOperationResult?> waitForInstall(
    String requestId, {
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final value = await rpc.call('pluginManager/waitForInstall', {'requestId': requestId}, timeout);
    return value == null ? null : PluginOperationResult.fromJson(value);
  }

  /// Unloads and removes a profile-owned bundle.
  Future<PluginOperationResult> removeBundle(String name, {Duration timeout = const Duration(minutes: 10)}) async =>
      PluginOperationResult.fromJson(await rpc.call('pluginManager/removeBundle', {'name': name}, timeout));

  Future<PluginRegistries> pluginRegistries() async =>
      PluginRegistries.fromJson(await rpc.call('pluginManager/registries'));
}

// -----------------------------------------------------------------------------
// Market index format 1
// -----------------------------------------------------------------------------

/// The index could not be read at all (not JSON, not format 1, no plugin list).
class MarketIndexException implements Exception {
  const MarketIndexException(this.path, this.reason);
  final String path;
  final String reason;

  @override
  String toString() => 'MarketIndexException: $path $reason';
}

/// An entry or member dropped while reading an index.
class MarketIndexIssue {
  const MarketIndexIssue(this.path, this.reason);
  final String path;
  final String reason;

  @override
  String toString() => '$path $reason';
}

/// A declared category or label.
class MarketDeclaration {
  const MarketDeclaration(this.id, this.title);
  final String id;
  final LocalizedText title;
}

class MarketSortKey {
  const MarketSortKey(this.id, this.title, {this.descending = true});
  final String id;
  final LocalizedText title;
  final bool descending;
}

sealed class MarketSource {
  const MarketSource();
}

final class MarketNpmSource extends MarketSource {
  const MarketNpmSource({this.registry});

  /// Registry to ask first; null = the host's configured one.
  final String? registry;
}

final class MarketGitSource extends MarketSource {
  const MarketGitSource({required this.url, required this.commit, this.path});
  final String url;
  final String commit;
  final String? path;
}

/// What to pass to [PluginsApi.installBundle].
class MarketInstallTarget {
  const MarketInstallTarget(this.spec, {this.registry});
  final String spec;
  final String? registry;
}

class MarketVersion {
  const MarketVersion({required this.version, required this.published, required this.source, this.enginesDsh});

  /// Exact SemVer.
  final String version;
  final DateTime published;
  final MarketSource source;

  /// `engines.dsh` range, unvalidated.
  final String? enginesDsh;

  /// `name@version` for npm (with the source registry), or a commit-pinned
  /// `git+<url>.git#<commit>[&path:/<dir>]` for git (`marketInstallTarget`).
  MarketInstallTarget installTarget(String name) => switch (source) {
    MarketNpmSource(:final registry) => MarketInstallTarget('$name@$version', registry: registry),
    MarketGitSource(:final url, :final commit, :final path) => MarketInstallTarget(
      'git+${url.endsWith('.git') ? url : '$url.git'}#$commit${path == null ? '' : '&path:/$path'}',
    ),
  };
}

class MarketPlugin {
  const MarketPlugin({
    required this.name,
    this.title,
    this.description,
    this.icon,
    this.author,
    this.homepage,
    this.repositoryUrl,
    this.repositoryDirectory,
    this.category,
    this.keywords = const [],
    this.labels = const [],
    this.sortKeys = const {},
    required this.versions,
  });

  /// npm package name (unique in the index).
  final String name;
  final LocalizedText? title;
  final LocalizedText? description;

  /// Absolute https URL (or same-origin URL) or an image `data:` URL.
  final String? icon;
  final String? author;
  final String? homepage;
  final String? repositoryUrl;
  final String? repositoryDirectory;

  /// Declared category id.
  final String? category;
  final List<String> keywords;

  /// Declared label ids.
  final List<String> labels;
  final Map<String, num> sortKeys;

  /// Non-empty, newest (highest SemVer precedence) first.
  final List<MarketVersion> versions;

  MarketVersion get latest => versions.first;

  String displayTitle([String locale = 'zh']) => title?.resolve(locale) ?? name;

  String? displayDescription([String locale = 'zh']) => description?.resolve(locale);
}

class MarketIndex {
  const MarketIndex({
    required this.url,
    required this.title,
    this.description,
    this.categories = const {},
    this.labels = const {},
    this.sortKeys = const {},
    this.plugins = const [],
    this.issues = const [],
  });

  final Uri url;
  final LocalizedText title;
  final LocalizedText? description;

  /// In declaration order.
  final Map<String, MarketDeclaration> categories;
  final Map<String, MarketDeclaration> labels;
  final Map<String, MarketSortKey> sortKeys;
  final List<MarketPlugin> plugins;

  /// Entries and members that were dropped (an empty list for a valid index).
  final List<MarketIndexIssue> issues;
}

final RegExp _languageId = RegExp(r'^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$');
final RegExp _packageName = RegExp(r'^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$');
const _numeric = r'(?:0|[1-9]\d*)';
const _prereleasePart = '(?:$_numeric|\\d*[a-zA-Z-][0-9a-zA-Z-]*)';
final RegExp _semver = RegExp(
  '^($_numeric)\\.($_numeric)\\.($_numeric)(?:-($_prereleasePart(?:\\.$_prereleasePart)*))?'
  r'(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?$',
);
final RegExp _commit = RegExp(r'^[0-9a-f]{40}$');
final RegExp _pathSegment = RegExp(r'^[A-Za-z0-9._@+-]+$');
final RegExp _dataIcon = RegExp(
  r'^data:(?:image/svg\+xml|image/png|image/jpeg|image/webp);base64,([A-Za-z0-9+/]*={0,2})$',
);

/// Largest decoded payload of an inline `data:` icon, in bytes.
const int maxInlineIconBytes = 32 * 1024;

/// Whether [version] is one exact SemVer 2.0.0 version.
bool isExactSemver(String version) => _semver.hasMatch(version);

/// SemVer precedence: negative when [a] < [b]. Invalid versions sort lowest
/// (and compare as strings among themselves).
int compareSemver(String a, String b) {
  final ma = _semver.firstMatch(a);
  final mb = _semver.firstMatch(b);
  if (ma == null || mb == null) {
    if (ma == null && mb == null) return a.compareTo(b);
    return ma == null ? -1 : 1;
  }
  for (var i = 1; i <= 3; i++) {
    final c = BigInt.parse(ma.group(i)!).compareTo(BigInt.parse(mb.group(i)!));
    if (c != 0) return c;
  }
  final pa = ma.group(4);
  final pb = mb.group(4);
  if (pa == null || pb == null) {
    if (pa == null && pb == null) return 0;
    return pa == null ? 1 : -1; // a release outranks its prereleases
  }
  final xa = pa.split('.');
  final xb = pb.split('.');
  for (var i = 0; i < xa.length && i < xb.length; i++) {
    final na = RegExp(r'^\d+$').hasMatch(xa[i]) ? BigInt.parse(xa[i]) : null;
    final nb = RegExp(r'^\d+$').hasMatch(xb[i]) ? BigInt.parse(xb[i]) : null;
    final int c;
    if (na != null && nb != null) {
      c = na.compareTo(nb);
    } else if (na != null || nb != null) {
      c = na != null ? -1 : 1; // numeric identifiers rank lower
    } else {
      c = xa[i].compareTo(xb[i]);
    }
    if (c != 0) return c;
  }
  return xa.length.compareTo(xb.length);
}

/// Reads a format-1 index ([json] already decoded) fetched from [indexUrl].
///
/// Lenient where the official validator is strict: a plugin that breaks a
/// rule is skipped (recorded in [MarketIndex.issues]), an invalid optional
/// member is dropped, versions that break a rule are dropped (the plugin is
/// skipped only when none remain), undeclared category/label/sort-key
/// references are ignored. Throws [MarketIndexException] only when the
/// document is not a format-1 index at all.
MarketIndex parseMarketIndex(Object? json, Uri indexUrl) {
  final root = asMap(json);
  if (root == null) throw const MarketIndexException(r'$', 'must be an object');
  if (asInt(root['format']) != 1) throw const MarketIndexException(r'$.format', 'must be 1');
  final rawPlugins = asList(root['plugins']);
  if (rawPlugins == null) throw const MarketIndexException(r'$.plugins', 'must be an array');
  final issues = <MarketIndexIssue>[];

  final metadata = asMapOrEmpty(root['metadata']);
  Map<String, T> declarations<T>(String key, T? Function(String id, JsonMap value, String path) read) {
    final out = <String, T>{};
    final raw = asMap(metadata[key]);
    if (raw == null) {
      if (metadata.containsKey(key)) issues.add(MarketIndexIssue('\$.metadata.$key', 'must be an object'));
      return out;
    }
    for (final MapEntry(key: id, :value) in raw.entries) {
      final path = '\$.metadata.$key.$id';
      final member = asMap(value);
      final parsed = id.isEmpty || member == null ? null : read(id, member, path);
      if (parsed == null) {
        issues.add(MarketIndexIssue(path, 'is not a valid declaration'));
      } else {
        out[id] = parsed;
      }
    }
    return out;
  }

  final categories = declarations<MarketDeclaration>('categories', (id, value, _) {
    final title = _strictLocalized(value['title']);
    return title == null ? null : MarketDeclaration(id, title);
  });
  final labels = declarations<MarketDeclaration>('labels', (id, value, _) {
    final title = _strictLocalized(value['title']);
    return title == null ? null : MarketDeclaration(id, title);
  });
  final sortKeys = declarations<MarketSortKey>('sortKeys', (id, value, _) {
    final title = _strictLocalized(value['title']);
    final order = value['order'];
    if (title == null || (order != 'asc' && order != 'desc')) return null;
    return MarketSortKey(id, title, descending: order == 'desc');
  });

  final names = <String>{};
  final plugins = <MarketPlugin>[];
  for (final (position, entry) in rawPlugins.indexed) {
    final path = '\$.plugins[$position]';
    final plugin = _plugin(entry, path, indexUrl, categories, labels, sortKeys, issues);
    if (plugin == null) continue;
    if (!names.add(plugin.name)) {
      issues.add(MarketIndexIssue('$path.name', 'duplicates ${plugin.name}'));
      continue;
    }
    plugins.add(plugin);
  }

  return MarketIndex(
    url: indexUrl,
    title: _strictLocalized(root['title']) ?? LocalizedText.plain(indexUrl.host),
    description: _strictLocalized(root['description']),
    categories: categories,
    labels: labels,
    sortKeys: sortKeys,
    plugins: plugins,
    issues: issues,
  );
}

/// Decodes JSON text and reads it with [parseMarketIndex].
MarketIndex parseMarketIndexText(String text, Uri indexUrl) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (error) {
    throw MarketIndexException(r'$', 'is not JSON (${error.message})');
  }
  return parseMarketIndex(json, indexUrl);
}

/// LocalizedText as format 1 defines it (a map must contain `en` and use
/// language ids); `null` when it does not qualify.
LocalizedText? _strictLocalized(Object? value) {
  if (value is String) return value.trim().isEmpty ? null : LocalizedText.plain(value);
  final map = asMap(value);
  if (map == null) return null;
  final values = <String, String>{};
  for (final MapEntry(:key, :value) in map.entries) {
    if (!_languageId.hasMatch(key) || value is! String || value.trim().isEmpty) return null;
    values[key] = value;
  }
  return values.containsKey('en') ? LocalizedText(values) : null;
}

String? _nonBlank(Object? value) => value is String && value.trim().isNotEmpty ? value : null;

Uri? _absoluteHttp(Object? value, {bool httpsOnly = false}) {
  final text = _nonBlank(value);
  final uri = text == null ? null : Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'https' && (httpsOnly || uri.scheme != 'http')) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri;
}

bool _validPackagePath(String text) =>
    text.split('/').every((segment) => segment != '.' && segment != '..' && _pathSegment.hasMatch(segment));

String? _icon(Object? value, Uri indexUrl) {
  final text = _nonBlank(value);
  if (text == null) return null;
  if (text.startsWith('data:')) {
    final payload = _dataIcon.firstMatch(text)?.group(1);
    if (payload == null || payload.isEmpty || payload.length % 4 != 0) return null;
    final padding = payload.endsWith('==') ? 2 : (payload.endsWith('=') ? 1 : 0);
    if (payload.length ~/ 4 * 3 - padding > maxInlineIconBytes) return null;
    return text;
  }
  final Uri resolved;
  try {
    resolved = indexUrl.resolve(text);
  } on FormatException {
    return null;
  }
  final sameOrigin =
      resolved.scheme == indexUrl.scheme && resolved.host == indexUrl.host && resolved.port == indexUrl.port;
  if (resolved.scheme == 'https' || (resolved.scheme == 'http' && sameOrigin)) {
    return resolved.toString();
  }
  return null;
}

MarketSource? _source(Object? value) {
  final map = asMap(value);
  if (map == null) return null;
  switch (map['type']) {
    case 'npm':
      final registry = map.containsKey('registry') ? _absoluteHttp(map['registry']) : null;
      if (map.containsKey('registry') && (registry == null || registry.hasQuery || registry.hasFragment)) return null;
      return MarketNpmSource(registry: registry?.toString());
    case 'git':
      final commit = asString(map['commit']);
      final url = _absoluteHttp(map['url'], httpsOnly: true);
      if (commit == null || !_commit.hasMatch(commit) || url == null) return null;
      if (url.hasQuery || url.hasFragment || url.toString() != map['url']) return null;
      if (url.pathSegments.where((s) => s.isNotEmpty).length < 2) return null;
      if (RegExp(r'\.(?:tgz|tar\.gz)$', caseSensitive: false).hasMatch(url.path)) return null;
      final dir = map.containsKey('path') ? _nonBlank(map['path']) : null;
      if (map.containsKey('path') && (dir == null || !_validPackagePath(dir))) return null;
      return MarketGitSource(url: url.toString(), commit: commit, path: dir);
    default:
      return null;
  }
}

MarketVersion? _version(Object? value) {
  final map = asMap(value);
  if (map == null) return null;
  final version = asString(map['version']);
  if (version == null || !_semver.hasMatch(version)) return null;
  final published = asInt(map['publishTimestamp']);
  if (published == null || published < 0 || published >= 100000000000) return null;
  final source = _source(map['source']);
  if (source == null) return null;
  final engines = asMap(map['engines']);
  final range = _nonBlank(engines?['dsh']);
  return MarketVersion(
    version: version,
    published: DateTime.fromMillisecondsSinceEpoch(published * 1000, isUtc: true),
    source: source,
    enginesDsh: range != null && !range.startsWith('workspace:') ? range : null,
  );
}

MarketPlugin? _plugin(
  Object? value,
  String path,
  Uri indexUrl,
  Map<String, MarketDeclaration> categories,
  Map<String, MarketDeclaration> labels,
  Map<String, MarketSortKey> sortKeys,
  List<MarketIndexIssue> issues,
) {
  final map = asMap(value);
  if (map == null) {
    issues.add(MarketIndexIssue(path, 'must be an object'));
    return null;
  }
  final name = asString(map['name']);
  if (name == null || name.length > 214 || !_packageName.hasMatch(name)) {
    issues.add(MarketIndexIssue('$path.name', 'must be a valid npm package name'));
    return null;
  }
  final versions = <MarketVersion>[];
  final seen = <String>{};
  for (final (position, raw) in asListOrEmpty(map['versions']).indexed) {
    final version = _version(raw);
    if (version == null || !seen.add(version.version)) {
      issues.add(MarketIndexIssue('$path.versions[$position]', 'is not a valid version entry'));
      continue;
    }
    versions.add(version);
  }
  if (versions.isEmpty) {
    issues.add(MarketIndexIssue('$path.versions', 'has no valid version'));
    return null;
  }
  versions.sort((a, b) => compareSemver(b.version, a.version));

  final meta = asMapOrEmpty(map['metadata']);
  final category = asString(meta['category']);
  final repository = asMap(map['repository']);
  final repositoryUrl = _absoluteHttp(repository?['url']);
  final directory = _nonBlank(repository?['directory']);
  final homepage = _absoluteHttp(map['homepage']);
  return MarketPlugin(
    name: name,
    title: LocalizedText.fromJson(map['title']),
    description: LocalizedText.fromJson(map['description']),
    icon: _icon(map['icon'], indexUrl),
    author: _nonBlank(map['author']),
    homepage: homepage?.toString(),
    repositoryUrl: repositoryUrl?.toString(),
    repositoryDirectory: repositoryUrl != null && directory != null && _validPackagePath(directory) ? directory : null,
    category: category != null && categories.containsKey(category) ? category : null,
    keywords: asStringList(meta['keywords']),
    labels: {
      for (final label in asStringList(meta['labels']))
        if (labels.containsKey(label)) label,
    }.toList(growable: false),
    sortKeys: {
      for (final MapEntry(:key, :value) in asMapOrEmpty(meta['sortKeys']).entries)
        if (sortKeys.containsKey(key) && value is num && value.isFinite) key: value,
    },
    versions: versions,
  );
}
