// Fakes for the ui.json tests: a source driven by hand, a fixed active host,
// a runtime whose phase the test sets, and a temp rootfs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The app's directory (tests run with `app/` as the working directory).
final appDir = Directory.current.path;

String fixturePath(String name) => '$appDir/test/ui_config/fixtures/$name';

String fixture(String name) => File(fixturePath(name)).readAsStringSync();

Map<String, Object?> expected(String name) =>
    jsonDecode(File(fixturePath(name.replaceFirst(RegExp(r'\.json$'), '.expected.json'))).readAsStringSync())
        as Map<String, Object?>;

/// Every fixture (not the `.expected.json` files), sorted.
List<String> fixtureNames() => [
  for (final f in Directory('$appDir/test/ui_config/fixtures').listSync())
    if (f is File && f.path.endsWith('.json') && !f.path.endsWith('.expected.json')) f.uri.pathSegments.last,
]..sort();

/// What both validators report for a fixture, in check.mjs's shape.
Map<String, Object?> summarize(UiConfigLoad load) => {
  'applied': load.appliedCount,
  'fatal': load.fatal,
  'issues': [for (final i in load.issues) i.toJson()],
};

/// A source the test feeds.
class FakeUiSource implements UiConfigSource {
  final controller = StreamController<UiConfigRead>();
  int listens = 0;

  @override
  Stream<UiConfigRead> watch() {
    listens++;
    return controller.stream;
  }

  void push(UiConfigRead read) => controller.add(read);

  void text(String text) => push(UiConfigText(text));
}

class TestActiveHost extends ActiveHostController {
  TestActiveHost(this.initial);

  final HostRef initial;

  @override
  HostRef build() => initial;

  @override
  void select(HostRef host) => state = host;
}

class TestRuntime extends LocalRuntimeController {
  TestRuntime(this.initial);

  final RuntimePhase initial;

  @override
  LocalRuntimeState build() => LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: initial));

  void setPhase(RuntimePhase phase) => state = LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: phase));
}

/// Overrides that route every host to [sources] (missing hosts: no source).
List<Override> sourceOverrides(Map<HostRef, UiConfigSource> sources, {HostRef active = HostRef.none}) => [
  activeHostProvider.overrideWith(() => TestActiveHost(active)),
  uiConfigKicksProvider.overrideWithValue(const Stream.empty()),
  uiConfigSourceBuilderProvider.overrideWithValue((ref, host) => sources[host]),
];

/// A throwaway rootfs with `/root/.dsh` (unless [withHome] is false).
Directory tempRootfs({bool withHome = true}) {
  final root = Directory.systemTemp.createTempSync('ui-config-rootfs-');
  if (withHome) Directory('${root.path}/root/.dsh').createSync(recursive: true);
  return root;
}

/// Waits (real time) until [test] holds or [timeout] passes.
Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Reads a bundled asset from disk (what rootBundle would give).
Future<String> readAssetFromDisk(String key) async => File('$appDir/$key').readAsString();
