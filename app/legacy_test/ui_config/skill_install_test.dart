// The dsh-go-ui skill: on-device install into a temp rootfs (managed line,
// updates, a folder the person took over), the auto-install on engine start,
// the SSH script run by a real /bin/sh, and the message for other hosts.

import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import 'skill_native_support.dart';

void main() {
  late UiSkillBundle bundle;
  late Directory root;

  setUpAll(() async => bundle = await loadUiSkillBundle(readAssetFromDisk));

  setUp(() => root = tempRootfs());
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory skillDir(Directory rootfs) => Directory('${rootfs.path}/root/.dsh/skills/dsh-go-ui');

  void expectInstalled(Directory dir) {
    for (final MapEntry(key: path, value: text) in bundle.files.entries) {
      expect(File('${dir.path}/$path').readAsStringSync(), text, reason: path);
    }
    expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.dsh-go-tmp')), isEmpty);
  }

  test('the bundle has the skill, the schema, the checker and examples in place', () {
    expect(bundle.files.keys, containsAll(['SKILL.md', 'schema.json', 'scripts/check.mjs', 'examples/full.json']));
    expect(bundle.writeOrder.last.key, 'SKILL.md');
  });

  test('installs, then leaves current files alone, then repairs a changed one', () async {
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.installed);
    expectInstalled(skillDir(root));

    final check = File('${skillDir(root).path}/scripts/check.mjs');
    final before = check.statSync().modified;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.unchanged);
    expect(check.statSync().modified, before);

    check.writeAsStringSync('// broken');
    File('${skillDir(root).path}/examples/full.json').deleteSync();
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.updated);
    expectInstalled(skillDir(root));
  });

  test('a SKILL.md without the managed line is the person\'s: not touched', () async {
    await installUiSkill(root, bundle);
    final skill = File('${skillDir(root).path}/SKILL.md');
    final mine = skill.readAsStringSync().replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), '');
    skill.writeAsStringSync('$mine\n我的补充\n');
    File('${skillDir(root).path}/schema.json').writeAsStringSync('{}');
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.userOwned);
    expect(skill.readAsStringSync(), endsWith('我的补充\n'));
    expect(File('${skillDir(root).path}/schema.json').readAsStringSync(), '{}');
  });

  test('no DSH home yet: nothing is written', () async {
    root.deleteSync(recursive: true);
    root = tempRootfs(withHome: false);
    expect(await installUiSkill(root, bundle), UiSkillInstallResult.noHome);
    expect(Directory('${root.path}/root').existsSync(), isFalse);
  });

  test('installs each time the engine comes up', () async {
    late SkillRuntime runtime;
    final c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime = SkillRuntime(RuntimePhase.installed)),
        runtimeBridgeProvider.overrideWithValue(SkillFileBridge()),
        uiRootfsResolverProvider.overrideWithValue(() async => root),
        uiSkillBundleLoaderProvider.overrideWithValue(() async => bundle),
      ],
    );
    addTearDown(c.dispose);
    c.listen(uiSkillAutoInstallProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(skillDir(root).existsSync(), isFalse, reason: 'not before the engine runs');

    runtime.setPhase(RuntimePhase.starting);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    runtime.setPhase(RuntimePhase.running);
    await until(() => c.read(uiSkillAutoInstallProvider) != null);
    expect(c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.installed);
    expectInstalled(skillDir(root));

    // A reset wipes it; the next start puts it back.
    skillDir(root).deleteSync(recursive: true);
    runtime.setPhase(RuntimePhase.stopping);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    runtime.setPhase(RuntimePhase.running);
    await until(() => skillDir(root).existsSync() && File('${skillDir(root).path}/SKILL.md').existsSync());
    await c.read(uiSkillAutoInstallProvider.notifier).running;
    expectInstalled(skillDir(root));
  });

  group('remote', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('ui-skill-home-'));
    tearDown(() => home.deleteSync(recursive: true));

    Future<ProcessResult> sh(String script, Map<String, String> env) =>
        Process.run('/bin/sh', ['-c', script], environment: env, includeParentEnvironment: false);

    test('the SSH script writes the skill under \$DSH_HOME, byte for byte', () async {
      final r = await sh(uiSkillShellScript(bundle), {'DSH_HOME': '${home.path}/dsh', 'PATH': '/usr/bin:/bin'});
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('DSHAPP skill=installed'));
      expectInstalled(Directory('${home.path}/dsh/skills/dsh-go-ui'));
    });

    test('without DSH_HOME it uses ~/.dsh, and leaves a folder the person took over', () async {
      final env = {'HOME': home.path, 'PATH': '/usr/bin:/bin'};
      expect((await sh(uiSkillShellScript(bundle), env)).exitCode, 0);
      final dir = Directory('${home.path}/.dsh/skills/dsh-go-ui');
      expectInstalled(dir);
      final skill = File('${dir.path}/SKILL.md');
      skill.writeAsStringSync(
        skill.readAsStringSync().replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), ''),
      );
      File('${dir.path}/schema.json').writeAsStringSync('{}');
      final r = await sh(uiSkillShellScript(bundle), env);
      expect(r.stdout, contains('DSHAPP skill=user-owned'));
      expect(File('${dir.path}/schema.json').readAsStringSync(), '{}');
    });

    test('the message for other hosts carries the working files', () {
      final prompt = uiSkillInstallPrompt(bundle);
      expect(prompt, contains(r'$DSH_HOME/skills/dsh-go-ui/'));
      for (final path in ['SKILL.md', 'schema.json', 'scripts/check.mjs']) {
        expect(prompt, contains('文件 `$path`：'));
        expect(prompt, contains(bundle.files[path]!.trimRight()));
      }
      expect(prompt, isNot(contains('examples/full.json')));
    });
  });
}
