import 'package:flutter/services.dart';

/// What the native side knows about the installed app.
class InstalledApp {
  const InstalledApp({
    this.versionName,
    this.versionCode,
    this.abi,
    this.canRequestInstalls = true,
    this.freeBytes,
    this.apkPath,
    this.lastUpdateTime,
  });

  factory InstalledApp.fromMap(Map<Object?, Object?> map) => InstalledApp(
    versionName: map['versionName'] as String?,
    versionCode: (map['versionCode'] as num?)?.toInt(),
    abi: map['abi'] as String?,
    canRequestInstalls: map['canRequestInstalls'] != false,
    freeBytes: (map['freeBytes'] as num?)?.toInt(),
    apkPath: map['apkPath'] as String?,
    lastUpdateTime: (map['lastUpdateTime'] as num?)?.toInt(),
  );

  final String? versionName;
  final int? versionCode;

  /// Native library dir name of this APK (`arm64`, `x86_64`).
  final String? abi;

  /// [abi] as Android names it (`arm64-v8a`), when it is one of the four.
  String? get androidAbi => switch (abi) {
    'arm64' => 'arm64-v8a',
    'arm' => 'armeabi-v7a',
    'x86_64' => 'x86_64',
    'x86' => 'x86',
    _ => null,
  };

  /// Android 8+ "install unknown apps" for this app.
  final bool canRequestInstalls;

  /// Free space where downloads go.
  final int? freeBytes;

  /// The installed APK (`applicationInfo.sourceDir`), which delta patches
  /// start from.
  final String? apkPath;

  /// When this build was installed (ms since the epoch). With [versionCode]
  /// it tells one installed build from another.
  final int? lastUpdateTime;
}

/// What an APK file is, compared with the installed app.
class ApkInspection {
  const ApkInspection({
    required this.valid,
    this.packageName,
    this.versionName,
    this.versionCode,
    this.samePackage = true,
    this.signatureMatches,
  });

  factory ApkInspection.fromMap(Map<Object?, Object?> map) => ApkInspection(
    valid: map['valid'] == true,
    packageName: map['packageName'] as String?,
    versionName: map['versionName'] as String?,
    versionCode: (map['versionCode'] as num?)?.toInt(),
    samePackage: map['samePackage'] != false,
    signatureMatches: map['signatureMatches'] as bool?,
  );

  /// The system could parse it.
  final bool valid;
  final String? packageName;
  final String? versionName;
  final int? versionCode;
  final bool samePackage;

  /// Null when the system wouldn't say; the installer decides then.
  final bool? signatureMatches;
}

enum InstallStatus {
  success,

  /// The person cancelled the system dialog.
  aborted,

  /// Signed with a different key than the installed app.
  signature,

  /// Older than what's installed.
  downgrade,

  /// Wrong SDK level, ABI, or missing feature.
  incompatible,
  storage,

  /// Corrupt or not an APK.
  invalid,

  /// A device policy or security app refused it.
  blocked,
  conflict,
  failure,
}

class InstallResult {
  const InstallResult(this.status, [this.message]);

  factory InstallResult.fromMap(Map<Object?, Object?> map) => InstallResult(
    InstallStatus.values.where((s) => s.name == map['status']).firstOrNull ?? InstallStatus.failure,
    map['message'] as String?,
  );

  final InstallStatus status;

  /// The system's own message (English, for logs).
  final String? message;
}

/// The native installer (PackageInstaller session API, `UpdatePlugin.kt`).
abstract interface class UpdateInstaller {
  Future<InstalledApp> installedApp();
  Future<bool> canRequestInstalls();

  /// Opens "install unknown apps" for this app; false when no settings page opened.
  Future<bool> openInstallPermission();
  Future<ApkInspection> inspect(String path);

  /// Resolves when the session ends: the person confirmed (the process is
  /// usually replaced before this returns), cancelled, or it failed.
  Future<InstallResult> install(String path);

  /// Opens the package in the system's own installer; false when it couldn't.
  Future<bool> openWithSystemInstaller(String path);
}

class ChannelUpdateInstaller implements UpdateInstaller {
  const ChannelUpdateInstaller();

  static const _channel = MethodChannel('dsh/update');

  Future<Map<Object?, Object?>> _map(String method, [Object? args]) async =>
      await _channel.invokeMethod<Map<Object?, Object?>>(method, args) ?? const {};

  @override
  Future<InstalledApp> installedApp() async => InstalledApp.fromMap(await _map('info'));

  @override
  Future<bool> canRequestInstalls() async => await _channel.invokeMethod<bool>('canRequestInstalls') ?? true;

  @override
  Future<bool> openInstallPermission() async => await _channel.invokeMethod<bool>('openInstallPermission') ?? false;

  @override
  Future<ApkInspection> inspect(String path) async => ApkInspection.fromMap(await _map('inspect', {'path': path}));

  @override
  Future<InstallResult> install(String path) async => InstallResult.fromMap(await _map('install', {'path': path}));

  @override
  Future<bool> openWithSystemInstaller(String path) async =>
      await _channel.invokeMethod<bool>('openWithSystem', {'path': path}) ?? false;
}
