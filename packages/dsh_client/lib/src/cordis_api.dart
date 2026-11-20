/// The Cordis plugin panel of the official Web client
/// (`@deepseek-ai/dsh-client-ui-cordis`, the badge at the bottom of the
/// sidebar): the Host's frame-wide inventory of dynamic plugin definitions
/// and the two lifecycle verbs that need no browser (`dynamicCordisRunner/*`
/// of `@deepseek-ai/dsh-cordis-host-runner`).
///
/// Verified against DSH 0.2.1-rc.2: the generated Remote typings
/// (`typert.remote-client.d.ts`, `types/types.d.ts`) and a throwaway
/// `dsh web` (`inventory` answers `[]` on a fresh Host; `stopFromPanel` and
/// `undefineFromPanel` answer `session/not-found` for an unknown
/// conversation).
///
/// What the official panel does that a native client cannot: approve a run
/// request, run or update a version with a browser half, and show the
/// plugin's own interface. The official Client runner executes that code
/// inside the DSH Web page, so those stay in the page.
///
/// Definitions live in the Host process only: an engine restart clears them.
/// Over the DSH Remote tunnel `dynamicCordisRunner/*` is not on the
/// allow-list ([CordisApi.canReadCordis] is false).
library;

import 'json.dart';
import 'session_api.dart';

/// Host events after which the official panel re-reads the inventory
/// (`ctx.remote.$on` in `ui-cordis`): it re-reads rather than patches, since
/// the announcements carry no labels.
const cordisInventoryEvents = {
  'cordis/dynamic-package',
  'cordis/dynamic-retract',
  'cordis/request-run',
  'cordis/request-run-resolved',
};

/// One immutable version of a dynamic plugin (`DynamicCordisInventoryPackage`).
class CordisPackage {
  const CordisPackage({
    required this.packageId,
    required this.name,
    this.purpose = '',
    this.hasHostHalf = false,
    this.hasClientHalf = false,
  });

  static CordisPackage? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['packageId']);
    if (map == null || id == null || id.isEmpty) return null;
    return CordisPackage(
      packageId: id,
      name: asString(map['name'])?.trim() ?? '',
      purpose: asString(map['purpose'])?.trim() ?? '',
      hasHostHalf: map['hasHostHalf'] == true,
      hasClientHalf: map['hasClientHalf'] == true,
    );
  }

  final String packageId;

  /// The label given at define time.
  final String name;

  /// What it is for, in the author's words.
  final String purpose;

  /// Code that runs in the Host process.
  final bool hasHostHalf;

  /// Code that runs inside a DSH Web page (its interface).
  final bool hasClientHalf;
}

/// Why the latest activation failed (`CordisRunDiagnostic`, stack dropped).
class CordisRunFailure {
  const CordisRunFailure({required this.phase, required this.message});

  /// `approval`, `host-load`, `host-apply`, `client-load`, `client-apply`
  /// or `client-render`.
  final String phase;
  final String message;
}

/// The latest activation attempt (`DynamicCordisRunAttempt`).
class CordisRunAttempt {
  const CordisRunAttempt({
    required this.pluginRunId,
    required this.packageId,
    required this.status,
    this.mode = 'run',
    this.requiresApproval = false,
    this.hostStatus,
    this.clientStatus,
    this.failure,
  });

  static CordisRunAttempt? fromJson(Object? json) {
    final map = asMap(json);
    final runId = asString(map?['pluginRunId']);
    final packageId = asString(map?['packageId']);
    if (map == null || runId == null || packageId == null) return null;
    final error = asMap(map['error']);
    return CordisRunAttempt(
      pluginRunId: runId,
      packageId: packageId,
      status: asString(map['status']) ?? '',
      mode: asString(map['mode']) ?? 'run',
      requiresApproval: map['requiresApproval'] == true,
      hostStatus: asString(asMap(map['host'])?['status']),
      clientStatus: asString(asMap(map['client'])?['status']),
      failure: error == null
          ? null
          : CordisRunFailure(phase: asString(error['phase']) ?? '', message: asString(error['message']) ?? ''),
    );
  }

  final String pluginRunId;
  final String packageId;

  /// `awaiting-approval`, `starting-host`, `client-pending`, `running`,
  /// `waiting`, `rejected`, `failed`, `cancelled` or `stopped`.
  final String status;

  /// `run` (start the current version) or `update` (replace it).
  final String mode;
  final bool requiresApproval;

  /// `absent`, `pending`, `stopped`, `running`, `waiting` or `failed`.
  final String? hostStatus;
  final String? clientStatus;
  final CordisRunFailure? failure;
}

/// What a row of the panel reads, without a page's own Client live set
/// (the official `visiblePanelStatus` minus the `client-pending` split).
enum CordisPluginStatus {
  /// Defined, not running.
  idle,

  /// A run waits for someone in a DSH Web page to allow it.
  awaitingApproval,

  /// The Host half is coming up.
  starting,

  /// Active on the Host.
  running,

  /// The latest attempt at the version shown failed.
  failed,
}

/// One dynamic plugin of the Host's inventory (`DynamicCordisInventoryRow`).
class CordisPlugin {
  const CordisPlugin({
    required this.pluginId,
    required this.agentId,
    this.packages = const [],
    this.currentPackageId,
    this.nextPackageId,
    this.activeRunId,
    this.activePackageId,
    this.latestRun,
  });

  /// Null for a row without its two identities.
  static CordisPlugin? fromJson(Object? json) {
    final map = asMap(json);
    final pluginId = asString(map?['pluginId']);
    final agentId = asString(map?['agentId']);
    if (map == null || pluginId == null || pluginId.isEmpty || agentId == null || agentId.isEmpty) {
      return null;
    }
    final active = asMap(map['activeRun']);
    return CordisPlugin(
      pluginId: pluginId,
      agentId: agentId,
      packages: [for (final p in asListOrEmpty(map['packages'])) ?CordisPackage.fromJson(p)],
      currentPackageId: asString(map['currentPackageId']),
      nextPackageId: asString(map['nextPackageId']),
      activeRunId: asString(active?['pluginRunId']),
      activePackageId: asString(active?['packageId']),
      latestRun: CordisRunAttempt.fromJson(map['latestRun']),
    );
  }

  final String pluginId;

  /// The conversation that owns the plugin.
  final String agentId;

  /// Versions in define order.
  final List<CordisPackage> packages;

  /// Last version that activated successfully.
  final String? currentPackageId;

  /// Version of a failed or in-progress switch.
  final String? nextPackageId;

  /// The current activation; null while stopped.
  final String? activeRunId;
  final String? activePackageId;
  final CordisRunAttempt? latestRun;

  CordisPackage? packageOf(String? id) => id == null ? null : packages.where((p) => p.packageId == id).firstOrNull;

  /// The version a row describes: the pending switch, else the current one,
  /// else the newest (the official panel's default selection).
  CordisPackage? get shown => packageOf(nextPackageId) ?? packageOf(currentPackageId) ?? packages.lastOrNull;

  /// The version that is running, when one is.
  CordisPackage? get active => packageOf(activePackageId);

  /// The label of [shown]; the plugin id when it has none.
  String get name {
    final label = shown?.name ?? '';
    return label.isEmpty ? pluginId : label;
  }

  String get purpose => shown?.purpose ?? '';

  bool get running => activeRunId != null;

  /// Some version draws its interface inside a DSH Web page.
  bool get hasInterface => packages.any((p) => p.hasClientHalf);

  CordisPluginStatus get status {
    final latest = latestRun;
    if (latest?.status == 'awaiting-approval') return CordisPluginStatus.awaitingApproval;
    if (latest?.status == 'failed' && latest!.packageId == shown?.packageId) return CordisPluginStatus.failed;
    if (!running) {
      return latest?.status == 'starting-host' ? CordisPluginStatus.starting : CordisPluginStatus.idle;
    }
    return CordisPluginStatus.running;
  }

  /// The latest failure, when [status] is [CordisPluginStatus.failed].
  CordisRunFailure? get failure => status == CordisPluginStatus.failed ? latestRun?.failure : null;
}

/// How `stopFromPanel` answered.
enum CordisStopOutcome {
  stopped,

  /// It had already stopped (the official panel counts this as done).
  notRunning,

  /// The Host no longer has the plugin.
  missing,
}

extension CordisApi on DshClient {
  /// The Host serves the inventory through this client's carrier (not over
  /// the DSH Remote tunnel).
  bool get canReadCordis => supportsEndpoint('dynamicCordisRunner/inventory');

  /// `dynamicCordisRunner/inventory`: every dynamic plugin on the Host, in
  /// the Host's order, whichever conversation owns it.
  Future<List<CordisPlugin>> cordisInventory() async => [
    for (final row in asListOrEmpty(await rpc.call('dynamicCordisRunner/inventory'))) ?CordisPlugin.fromJson(row),
  ];

  /// `dynamicCordisRunner/stopFromPanel`: releases the running version and
  /// keeps the definition. The Host tells the owning conversation.
  Future<CordisStopOutcome> stopCordisPlugin(CordisPlugin plugin) async {
    final value = asMapOrEmpty(
      await rpc.call('dynamicCordisRunner/stopFromPanel', {'agentId': plugin.agentId, 'pluginId': plugin.pluginId}),
    );
    if (value['ok'] == true) return CordisStopOutcome.stopped;
    return value['reason'] == 'not-running' ? CordisStopOutcome.notRunning : CordisStopOutcome.missing;
  }

  /// `dynamicCordisRunner/undefineFromPanel`: stops it and removes every
  /// version. False when the Host no longer had it.
  Future<bool> removeCordisPlugin(CordisPlugin plugin) async {
    final value = asMapOrEmpty(
      await rpc.call('dynamicCordisRunner/undefineFromPanel', {'agentId': plugin.agentId, 'pluginId': plugin.pluginId}),
    );
    return value['ok'] == true;
  }
}
