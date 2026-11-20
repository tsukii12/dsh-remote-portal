// Development entry point (plugin seats end to end): the real app, with its
// on-device engine swapped for a DSH reached through `adb reverse` — a staged
// runtime (route guard + dsh-go-bridge) running on the build machine. Not part
// of any release.
//
//   tooling/build-apk.sh --debug -f x64 -t lib/dev/seams_e2e_main.dart
//
// The engine's address and launch token come from `files/seams_e2e.json`
// (`adb shell run-as … sh -c 'cat > files/seams_e2e.json'`):
//   {"url": "http://127.0.0.1:38095", "token": "…"}
// Without it the app runs as usual.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';

/// The engine on the build machine, always running.
class _HostEngine extends LocalRuntimeController {
  _HostEngine(this.status);

  final RuntimeStatus status;

  @override
  LocalRuntimeState build() => LocalRuntimeState(loaded: true, status: status);

  @override
  Future<void> install() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}
}

Future<RuntimeStatus?> _readStatus() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final json = jsonDecode(await File('${dir.path}/seams_e2e.json').readAsString()) as Map;
    final url = json['url'] as String;
    final token = json['token'] as String;
    debugPrint('[seams-e2e] engine at $url');
    const version = 'r5-dsh0.2.1-rc.2-host';
    return RuntimeStatus(
      phase: RuntimePhase.running,
      abi: 'x86_64',
      bundledVersion: version,
      installedVersion: version,
      dshVersion: '0.2.1-rc.2',
      nodeVersion: '24.22.1',
      baseUrl: url,
      token: token,
    );
  } catch (e) {
    debugPrint('[seams-e2e] no config ($e): the app as usual');
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final status = await _readStatus();
  runApp(
    ProviderScope(
      overrides: [if (status != null) localRuntimeProvider.overrideWith(() => _HostEngine(status))],
      child: const DshApp(),
    ),
  );
}
