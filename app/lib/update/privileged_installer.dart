import 'package:flutter/services.dart';

enum UpdateInstallRoute {
  system,
  shizuku,
  adb;

  static UpdateInstallRoute? parse(Object? value) => switch (value) {
    'shizuku' => shizuku,
    'adb' => adb,
    _ => null,
  };
}

Map<Object?, Object?> _map(Object? value) => value is Map ? value.cast<Object?, Object?>() : const {};

String? _code(Object? value) =>
    value is String && RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(value) ? value : null;

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;

enum SelfUpdatePendingState { none, pending, unknown, installed, superseded, failed }

/// Native evidence, not a local timeout or an acknowledgement of dispatch.
class SelfUpdatePending {
  const SelfUpdatePending({
    this.state = SelfUpdatePendingState.none,
    this.backend,
    this.versionCode,
    this.errorCode,
    this.canAcknowledge = false,
  });

  factory SelfUpdatePending.fromMap(Map<Object?, Object?> value) => SelfUpdatePending(
    state: SelfUpdatePendingState.values.where((state) => state.name == value['state']).firstOrNull ??
        SelfUpdatePendingState.unknown,
    backend: UpdateInstallRoute.parse(value['backend']),
    versionCode: _positiveInt(value['versionCode']),
    errorCode: _code(value['errorCode']),
    canAcknowledge: value['canAcknowledge'] == true,
  );

  final SelfUpdatePendingState state;
  final bool canAcknowledge;
  final UpdateInstallRoute? backend;
  final int? versionCode;
  final String? errorCode;

  bool get unresolved => state == SelfUpdatePendingState.pending || state == SelfUpdatePendingState.unknown;
  bool get verified => state == SelfUpdatePendingState.installed || state == SelfUpdatePendingState.superseded;
}

class PrivilegedInstallStatus {
  const PrivilegedInstallStatus({
    this.supported = false,
    this.shizukuInstalled = false,
    this.shizukuRunning = false,
    this.shizukuGranted = false,
    this.shizukuUid,
    this.adbPaired = false,
    this.pending = const SelfUpdatePending(),
    this.errorCode,
  });

  factory PrivilegedInstallStatus.fromMap(Map<Object?, Object?> value) {
    if (value['v'] != 1 || value['v'] is! int) {
      return const PrivilegedInstallStatus(errorCode: 'protocolMismatch');
    }
    final shizuku = _map(value['shizuku']);
    final adb = _map(value['adb']);
    return PrivilegedInstallStatus(
      supported: true,
      shizukuInstalled: shizuku['installed'] == true,
      shizukuRunning: shizuku['running'] == true,
      shizukuGranted: shizuku['granted'] == true,
      shizukuUid: shizuku['uid'] is int ? shizuku['uid'] as int : null,
      adbPaired: adb['paired'] == true,
      pending: value['pending'] is Map ? SelfUpdatePending.fromMap(_map(value['pending'])) : const SelfUpdatePending(),
    );
  }

  final bool supported;
  final bool shizukuInstalled;
  final bool shizukuRunning;
  final bool shizukuGranted;
  final int? shizukuUid;
  final bool adbPaired;
  final SelfUpdatePending pending;
  final String? errorCode;
}

enum PrivilegedInstallOutcome { success, aborted, blocked, incompatible, invalid, storage, failed, unavailable, unknown }

class PrivilegedInstallResult {
  const PrivilegedInstallResult({
    this.status = PrivilegedInstallOutcome.unknown,
    this.errorCode,
    this.submitted = false,
    this.outcomeUnknown = true,
  });

  factory PrivilegedInstallResult.fromMap(Map<Object?, Object?> value) => PrivilegedInstallResult(
    status: switch (value['status']) {
      'failure' || 'signature' || 'downgrade' || 'conflict' => PrivilegedInstallOutcome.failed,
      _ => PrivilegedInstallOutcome.values.where((status) => status.name == value['status']).firstOrNull ??
          PrivilegedInstallOutcome.unknown,
    },
    errorCode: _code(value['errorCode']) ?? switch (value['status']) {
      'signature' => 'signatureMismatch',
      'downgrade' => 'notNewer',
      'conflict' => 'installConflict',
      _ => null,
    },
    submitted: value['submitted'] == true,
    outcomeUnknown: value['outcomeUnknown'] != false,
  );

  final PrivilegedInstallOutcome status;
  final String? errorCode;
  final bool submitted;
  final bool outcomeUnknown;
}

abstract interface class PrivilegedInstaller {
  Future<PrivilegedInstallStatus> status();
  Future<bool> requestShizukuPermission();
  Future<PrivilegedInstallResult> install({
    required String path,
    required String sha256,
    required int versionCode,
    required UpdateInstallRoute backend,
    int? port,
  });
  Future<SelfUpdatePending> reconcile();
  Future<SelfUpdatePending> acknowledgeUnknown();
}

/// Separate from Phone control and Android Shell. Status/reconcile never set up
/// a transport; permission and installation each require an explicit action.
class ChannelPrivilegedInstaller implements PrivilegedInstaller {
  const ChannelPrivilegedInstaller();

  static const _channel = MethodChannel('dsh/update');

  @override
  Future<PrivilegedInstallStatus> status() async {
    try {
      return PrivilegedInstallStatus.fromMap(_map(await _channel.invokeMethod<Object?>('privilegedInstallStatus')));
    } on MissingPluginException {
      return const PrivilegedInstallStatus(errorCode: 'nativeUnavailable');
    } on PlatformException catch (error) {
      return PrivilegedInstallStatus(errorCode: _code(error.code) ?? 'invalidResponse');
    }
  }

  @override
  Future<bool> requestShizukuPermission() async {
    try {
      return await _channel.invokeMethod<Object?>('requestUpdateShizukuPermission') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<PrivilegedInstallResult> install({
    required String path,
    required String sha256,
    required int versionCode,
    required UpdateInstallRoute backend,
    int? port,
  }) async {
    if (backend == UpdateInstallRoute.system || versionCode <= 0 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256) ||
        (port != null && (port < 1 || port > 65535))) {
      return const PrivilegedInstallResult(
        status: PrivilegedInstallOutcome.invalid, errorCode: 'invalidArguments', outcomeUnknown: false,
      );
    }
    try {
      return PrivilegedInstallResult.fromMap(_map(await _channel.invokeMethod<Object?>('installPrivileged', {
        'path': path, 'sha256': sha256, 'versionCode': versionCode, 'backend': backend.name, 'port': ?port,
      })));
    } on MissingPluginException {
      return const PrivilegedInstallResult(
        status: PrivilegedInstallOutcome.unavailable, errorCode: 'nativeUnavailable', outcomeUnknown: false,
      );
    } on PlatformException catch (error) {
      // The native call may have dispatched before the connection was lost.
      return PrivilegedInstallResult(errorCode: _code(error.code) ?? 'invalidResponse');
    }
  }

  @override
  Future<SelfUpdatePending> acknowledgeUnknown() async =>
      SelfUpdatePending.fromMap(_map(await _channel.invokeMethod<Object?>('acknowledgeUnknownSelfUpdate')));

  @override
  Future<SelfUpdatePending> reconcile() async {
    final value = await _channel.invokeMethod<Object?>('reconcileSelfUpdate');
    if (value is! Map || value['state'] is! String) throw PlatformException(code: 'invalidResponse');
    return SelfUpdatePending.fromMap(value.cast<Object?, Object?>());
  }
}
