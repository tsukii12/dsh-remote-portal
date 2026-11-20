// Older app versions could save the session-only Auto preset as the default
// for new chats (`permission.defaultPreset: auto`; #26 stopped offering it).
// DSH 0.2.1 resolves that default when its permission presets start, before
// Auto is registered, so the plugin fails on every launch: no
// `permissionPresets` service, and no settings write either (`settings/mutate`
// and the plugin-config bridge only edit active plugins). The on-device
// engine's settings layer is a file the app can reach, so the app takes the
// value out of it and restarts DSH, which then starts the presets with its own
// default. A remote host offers no method that could, and is left alone.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

import '../runtime/runtime_state.dart';
import '../share_code/guest_fs.dart';
import 'engine_control.dart';

/// The main profile's settings layer, where DSH's settings forms write.
const mainProfilePatch = '${GuestFs.dshHome}/profiles/web/cordis.patch.yml';

/// Takes a stored Auto default out of the on-device engine's main profile and
/// restarts DSH so its permission presets load. Nothing to take out: nothing
/// happens, so this runs on every local connect and acts once.
Future<void> clearAutoDefaultPreset(ProviderContainer container) async {
  try {
    final file = (await container.read(guestFsProvider.future))?.file(mainProfilePatch);
    if (file == null || !file.existsSync()) return;
    final fixed = withoutAutoDefaultPreset(file.readAsStringSync());
    if (fixed == null) return;
    final tmp = File('${file.path}.dsh-go-tmp')..writeAsStringSync(fixed, flush: true);
    tmp.renameSync(file.path);
    debugPrint('Permissions: cleared the stored Auto default for new chats');
    // Safe mode runs its own profile; leaving it starts the fixed one.
    if (!container.read(localRuntimeProvider).status.inSafeMode) await EngineControl.restart(container);
  } catch (error) {
    // The next connect tries again.
    debugPrint('Permissions: could not clear the stored Auto default: $error');
  }
}

/// [patch] without `defaultPreset: auto` in its `permission` rows (the whole
/// `config` when that is all it holds), or null when there is none or it is
/// not laid out one field per line, as DSH writes it.
String? withoutAutoDefaultPreset(String patch) {
  final Object? rows;
  try {
    rows = loadYaml(patch);
  } on YamlException {
    return null;
  }
  if (rows is! YamlList) return null;
  final cuts = <(int, int)>[];
  for (final row in rows.nodes) {
    if (row is! YamlMap || row['id'] != 'permission' || row.containsKey('insert')) continue;
    final config = row.nodes['config'];
    if (config is! YamlMap || config['defaultPreset'] != 'auto') continue;
    final (owner, field) = config.length == 1 ? (row, 'config') : (config, 'defaultPreset');
    final key = owner.nodes.keys.cast<YamlNode>().firstWhere((k) => k.value == field).span.start.offset;
    final value = config.nodes['defaultPreset']!.span.end.offset;
    final start = patch.lastIndexOf('\n', key) + 1;
    final newline = patch.indexOf('\n', value);
    final end = newline < 0 ? patch.length : newline + 1;
    final rest = patch.substring(value, end).trim();
    if (patch.substring(start, key).trim().isNotEmpty || rest.isNotEmpty && !rest.startsWith('#')) return null;
    cuts.add((start, end));
  }
  if (cuts.isEmpty) return null;
  var out = patch;
  for (final (start, end) in cuts.reversed) {
    out = out.replaceRange(start, end, '');
  }
  return out;
}
