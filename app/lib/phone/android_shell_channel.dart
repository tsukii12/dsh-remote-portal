import 'package:flutter/services.dart';

Map<Object?, Object?> _map(Object? value) => value is Map ? value.cast<Object?, Object?>() : const {};

String? _code(Object? value) =>
    value is String && RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(value) ? value : null;

int? _nonNegativeInt(Object? value) => value is int && value >= 0 ? value : null;

enum AndroidShellBackend {
  shizuku,
  adb;

  static AndroidShellBackend? parse(Object? value) => switch (value) {
    'shizuku' => shizuku,
    'adb' => adb,
    _ => null,
  };
}

class AndroidShellShizukuStatus {
  const AndroidShellShizukuStatus({this.installed = false, this.running = false, this.granted = false});

  factory AndroidShellShizukuStatus.fromMap(Map<Object?, Object?> value) => AndroidShellShizukuStatus(
    installed: value['installed'] == true,
    running: value['running'] == true,
    granted: value['granted'] == true,
  );

  final bool installed;
  final bool running;
  final bool granted;
}

class AndroidShellAdbStatus {
  const AndroidShellAdbStatus({this.paired = false, this.connected = false});

  factory AndroidShellAdbStatus.fromMap(Map<Object?, Object?> value) =>
      AndroidShellAdbStatus(paired: value['paired'] == true, connected: value['connected'] == true);

  final bool paired;
  final bool connected;
}

/// Independent of the screen-control/background-display status and permissions.
class AndroidShellStatus {
  const AndroidShellStatus({
    this.supported = false,
    this.enabled = false,
    this.backend = AndroidShellBackend.shizuku,
    this.ready = false,
    this.uid,
    this.reasonCode,
    this.shizuku = const AndroidShellShizukuStatus(),
    this.adb = const AndroidShellAdbStatus(),
    this.limits = const {},
  });

  const AndroidShellStatus.unavailable(String code) : this(reasonCode: code);

  factory AndroidShellStatus.fromMap(Map<Object?, Object?> value) {
    if (value['v'] != 1 || value['v'] is! int) {
      return const AndroidShellStatus.unavailable('protocolMismatch');
    }
    final backend = AndroidShellBackend.parse(value['backend']);
    if (backend == null || value['enabled'] is! bool || value['ready'] is! bool) {
      return const AndroidShellStatus.unavailable('invalidResponse');
    }
    final limits = _map(value['limits']);
    return AndroidShellStatus(
      supported: true,
      enabled: value['enabled'] == true,
      backend: backend,
      ready: value['ready'] == true,
      uid: _nonNegativeInt(value['uid']),
      reasonCode: _code(value['reasonCode']),
      shizuku: AndroidShellShizukuStatus.fromMap(_map(value['shizuku'])),
      adb: AndroidShellAdbStatus.fromMap(_map(value['adb'])),
      limits: Map.unmodifiable({
        for (final key in const ['defaultTimeoutMs', 'maxTimeoutMs', 'maxOutputBytes', 'maxCommandBytes'])
          key: ?_nonNegativeInt(limits[key]),
      }),
    );
  }

  final bool supported;
  final bool enabled;
  final AndroidShellBackend backend;
  final bool ready;
  final int? uid;
  final String? reasonCode;
  final AndroidShellShizukuStatus shizuku;
  final AndroidShellAdbStatus adb;
  final Map<String, int> limits;
}

class AndroidShellResult {
  const AndroidShellResult(this.ok, {this.errorCode});

  factory AndroidShellResult.fromMap(Map<Object?, Object?> value) {
    if (value['ok'] == true) return const AndroidShellResult(true);
    return AndroidShellResult(false, errorCode: _code(value['errorCode']) ?? 'invalidResponse');
  }

  final bool ok;
  final String? errorCode;
}

/// Setup only: opening/refreshing never authorizes, connects or runs a command.
/// Native reason/exception messages are deliberately not surfaced: they may
/// contain pairing input. The UI localizes stable error codes instead.
class AndroidShellChannel {
  const AndroidShellChannel();

  static const _channel = MethodChannel('dsh/phone');

  Future<AndroidShellStatus> status() async {
    try {
      final value = await _channel.invokeMethod<Object?>('androidShellStatus');
      if (value is! Map) return const AndroidShellStatus.unavailable('invalidResponse');
      return AndroidShellStatus.fromMap(value.cast<Object?, Object?>());
    } on MissingPluginException {
      return const AndroidShellStatus.unavailable('nativeUnavailable');
    } on PlatformException catch (error) {
      return AndroidShellStatus.unavailable(_code(error.code) ?? 'invalidResponse');
    }
  }

  Future<AndroidShellResult> configure({required bool enabled, required AndroidShellBackend backend}) =>
      _result('configureAndroidShell', {'enabled': enabled, 'backend': backend.name});

  Future<bool> requestPermission() => _bool('androidShellRequestPermission');

  Future<AndroidShellResult> startPairing() => _result('androidShellStartPairing');

  Future<AndroidShellResult> pair(String code, {int? port}) {
    if (code.length != 6 || !RegExp(r'^[0-9]{6}$').hasMatch(code) || !_validPort(port)) {
      return Future.value(const AndroidShellResult(false, errorCode: 'invalidArguments'));
    }
    return _result('androidShellPair', {'code': code, 'port': ?port});
  }

  Future<AndroidShellResult> connect({int? port}) {
    if (!_validPort(port)) return Future.value(const AndroidShellResult(false, errorCode: 'invalidArguments'));
    return _result('androidShellConnect', {'port': ?port});
  }

  Future<bool> stop() => _bool('androidShellStop');

  bool _validPort(int? port) => port == null || (port >= 1 && port <= 65535);

  Future<AndroidShellResult> _result(String method, [Map<String, Object?>? arguments]) async {
    try {
      final value = await _channel.invokeMethod<Object?>(method, arguments);
      return AndroidShellResult.fromMap(_map(value));
    } on MissingPluginException {
      return const AndroidShellResult(false, errorCode: 'nativeUnavailable');
    } on PlatformException catch (error) {
      return AndroidShellResult(false, errorCode: _code(error.code) ?? 'invalidResponse');
    }
  }

  Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method) == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
