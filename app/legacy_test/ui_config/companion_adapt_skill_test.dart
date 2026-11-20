import 'dart:io';

import 'package:dsh_app/companion/companion_adapt.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'skill_native_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the installed full-mode contract is exactly the light prompt; user ownership persists', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, companionAdaptSkillName);
    expect(bundle.files['references/contract.txt'], companionAdaptSystem);
    expect(bundle.writeOrder.last.key, 'SKILL.md');
    expect(isManagedUiSkill(bundle.skillMd), isTrue);
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.installed);
    final installed = Directory('${root.path}/root/.dsh/skills/$companionAdaptSkillName');
    expect(File('${installed.path}/references/contract.txt').readAsStringSync(), companionAdaptSystem);
    final skill = File('${installed.path}/SKILL.md');
    skill.writeAsStringSync(bundle.skillMd.replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), ''));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.userOwned);
  });

  test('engine lifecycle installs the actual companion bundle through the managed transaction', () async {
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    final ui = await loadUiSkillBundle(readAssetFromDisk);
    final companion = await loadUiSkillBundle(readAssetFromDisk, companionAdaptSkillName);
    late SkillRuntime runtime;
    final container = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime = SkillRuntime(RuntimePhase.installed)),
        runtimeBridgeProvider.overrideWithValue(SkillFileBridge()),
        uiRootfsResolverProvider.overrideWithValue(() async => root),
        uiSkillBundleLoaderProvider.overrideWithValue(() async => ui),
        extraSkillLoadersProvider.overrideWithValue([() async => companion]),
      ],
    );
    addTearDown(container.dispose);
    container.listen(uiSkillAutoInstallProvider, (_, _) {});
    runtime.setPhase(RuntimePhase.running);
    await until(() => container.read(uiSkillAutoInstallProvider) != null);
    await container.read(uiSkillAutoInstallProvider.notifier).running;
    expect(
      File('${root.path}/root/.dsh/skills/companion-adapt/references/contract.txt').readAsStringSync(),
      companionAdaptSystem,
    );
  });
}
