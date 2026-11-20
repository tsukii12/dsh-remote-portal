// Fakes for the updater: HTTP routes keyed by URL, a scripted native installer,
// fixture loading, DSHDLT01 patches.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/update_http.dart';

String fixture(String name) => File('test/update/fixtures/$name').readAsStringSync();

typedef Route = FutureOr<UpdateHttpResponse> Function(Uri url, Map<String, String> headers);

/// Unknown URLs fail like an unreachable host.
class FakeHttp implements UpdateHttp {
  FakeHttp([Map<String, Route>? routes]) : routes = routes ?? {};

  final Map<String, Route> routes;
  final requests = <(Uri, Map<String, String>)>[];

  List<String> get urls => [for (final (url, _) in requests) url.toString()];

  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    requests.add((url, headers));
    final route = routes[url.toString()];
    if (route == null) throw SocketException('unreachable: ${url.host}');
    return route(url, headers);
  }
}

UpdateHttpResponse textResponse(String body, {int status = 200, Map<String, String> headers = const {}}) {
  final bytes = utf8.encode(body);
  return UpdateHttpResponse(status: status, headers: headers, contentLength: bytes.length, body: Stream.value(bytes));
}

/// Serves [bytes] honouring `Range: bytes=N-`. [dropAfter] cuts the stream
/// with an error after that many bytes of this response.
Route fileRoute(List<int> bytes, {int? dropAfter, bool ranges = true, void Function(int? start)? onRequest}) {
  return (url, headers) {
    final range = RegExp(r'bytes=(\d+)-').firstMatch(headers['range'] ?? '');
    final start = ranges && range != null ? int.parse(range.group(1)!) : 0;
    onRequest?.call(range == null ? null : start);
    if (start >= bytes.length && start > 0) {
      return UpdateHttpResponse(status: 416, body: const Stream.empty());
    }
    final slice = bytes.sublist(start);
    Stream<List<int>> body() async* {
      const chunk = 4;
      for (var i = 0; i < slice.length; i += chunk) {
        if (dropAfter != null && i >= dropAfter) throw const SocketException('connection reset');
        yield slice.sublist(i, i + chunk > slice.length ? slice.length : i + chunk);
      }
    }

    return UpdateHttpResponse(
      status: start > 0 ? 206 : 200,
      headers: {if (start > 0) 'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}'},
      contentLength: slice.length,
      body: body(),
    );
  };
}

/// Scripted native side; records calls.
class FakeInstaller implements UpdateInstaller {
  FakeInstaller({
    this.app = const InstalledApp(versionName: '1.0.0', versionCode: 1, abi: 'arm64', freeBytes: 8 << 30),
    this.canInstall = true,
    this.inspection = const ApkInspection(
      valid: true,
      packageName: 'io.github.ccch1mneyyy.dsh_app',
      signatureMatches: true,
    ),
    this.result = const InstallResult(InstallStatus.success),
  });

  InstalledApp app;
  bool canInstall;
  ApkInspection inspection;
  InstallResult result;
  final calls = <String>[];

  /// Paths handed to `install`, in order.
  final installed = <String>[];

  /// When set, `install` waits for it (a system dialog that's still open).
  Completer<InstallResult>? pending;

  /// When set, `inspect` waits for it (a slow APK parse).
  Completer<ApkInspection>? pendingInspect;

  /// Resolves once [method] has been called [times] times in all.
  Future<void> called(String method, {int times = 1}) async {
    while (calls.where((c) => c == method).length < times) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  Future<InstalledApp> installedApp() async => app;

  @override
  Future<bool> canRequestInstalls() async {
    calls.add('canRequestInstalls');
    return canInstall;
  }

  @override
  Future<bool> openInstallPermission() async {
    calls.add('openInstallPermission');
    return true;
  }

  @override
  Future<ApkInspection> inspect(String path) async {
    calls.add('inspect');
    return pendingInspect?.future ?? inspection;
  }

  @override
  Future<InstallResult> install(String path) async {
    calls.add('install');
    installed.add(path);
    return pending?.future ?? result;
  }

  /// What `openWithSystemInstaller` answers.
  bool systemInstallerOpens = true;

  @override
  Future<bool> openWithSystemInstaller(String path) async {
    calls.add('openWithSystemInstaller');
    installed.add(path);
    return systemInstallerOpens;
  }
}

Uint8List _u64(int value) => (ByteData(8)..setUint64(0, value)).buffer.asUint8List();

/// A DSHDLT01 patch from [base] to [target]: the header, then [ops] as they are.
List<int> deltaPatch(List<int> base, List<int> target, List<List<int>> ops) => [
  ...ascii.encode('DSHDLT01'),
  ...sha256.convert(base).bytes,
  ...sha256.convert(target).bytes,
  ..._u64(target.length),
  for (final op in ops) ...op,
];

List<int> deltaCopy(int offset, int length) => [0x01, ..._u64(offset), ..._u64(length)];
List<int> deltaData(List<int> bytes) => [0x02, ..._u64(bytes.length), ...bytes];
const deltaEnd = [0x00];
