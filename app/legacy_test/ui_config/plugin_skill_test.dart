// The dsh-go-plugin skill (built from sdk/plugin-kit by scripts/sync-skill.mjs): it loads
// from its own asset folder, installs into its own skills folder with the same managed-line
// rules as dsh-go-ui, and the engine-start auto-install puts both skills in place.

import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import 'skill_native_support.dart';

void main() {
  late UiSkillBundle ui;
  late UiSkillBundle plugin;
  late Directory root;

  setUpAll(() async {
    ui = await loadUiSkillBundle(readAssetFromDisk);
    plugin = await loadUiSkillBundle(readAssetFromDisk, pluginSkillName);
  });

  setUp(() => root = tempRootfs());
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory dirOf(String name) => Directory('${root.path}/root/.dsh/skills/$name');

  test('the plugin skill bundle: checker, schemas, template; SKILL.md last and managed', () {
    expect(plugin.name, pluginSkillName);
    expect(ui.name, uiSkillName);
    expect(
      plugin.files.keys,
      containsAll([
        'SKILL.md',
        'kit/bin/check.mjs',
        'kit/lib/check.js',
        'kit/lib/bridge/manifest.js',
        'kit/schema/view.schema.json',
        'template/package.json',
        'template/cordis.patch.yml',
        'template/lib/index.js',
      ]),
    );
    expect(plugin.writeOrder.last.key, 'SKILL.md');
    expect(isManagedUiSkill(plugin.skillMd), isTrue);
  });

  test('installs into skills/dsh-go-plugin, next to dsh-go-ui, with the same rules', () async {
    expect(await installUiSkill(root, plugin), UiSkillInstallResult.installed);
    for (final MapEntry(key: path, value: text) in plugin.files.entries) {
      expect(File('${dirOf(pluginSkillName).path}/$path').readAsStringSync(), text, reason: path);
    }
    expect(dirOf(uiSkillName).existsSync(), isFalse);
    expect(await installUiSkill(root, plugin), UiSkillInstallResult.unchanged);

    final skill = File('${dirOf(pluginSkillName).path}/SKILL.md');
    skill.writeAsStringSync(
      skill.readAsStringSync().replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), ''),
    );
    expect(await installUiSkill(root, plugin), UiSkillInstallResult.userOwned);
  });

  test('the SSH script writes the plugin skill into its own folder', () {
    final script = uiSkillShellScript(plugin);
    expect(script, contains('/skills/dsh-go-plugin"'));
    expect(script, contains('"\$d/kit/lib/bridge"'));
  });

  test('engine start installs both skills', () async {
    late SkillRuntime runtime;
    final c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime = SkillRuntime(RuntimePhase.installed)),
        runtimeBridgeProvider.overrideWithValue(SkillFileBridge()),
        uiRootfsResolverProvider.overrideWithValue(() async => root),
        uiSkillBundleLoaderProvider.overrideWithValue(() async => ui),
        extraSkillLoadersProvider.overrideWithValue([() async => plugin]),
      ],
    );
    addTearDown(c.dispose);
    c.listen(uiSkillAutoInstallProvider, (_, _) {});
    runtime.setPhase(RuntimePhase.running);
    await until(() => c.read(uiSkillAutoInstallProvider) != null);
    await c.read(uiSkillAutoInstallProvider.notifier).running;
    expect(c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.installed);
    expect(File('${dirOf(uiSkillName).path}/SKILL.md').existsSync(), isTrue);
    expect(File('${dirOf(pluginSkillName).path}/SKILL.md').existsSync(), isTrue);
    expect(File('${dirOf(pluginSkillName).path}/kit/bin/check.mjs').existsSync(), isTrue);
  });
}
