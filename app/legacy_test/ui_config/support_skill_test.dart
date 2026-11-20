// The dsh-go-support skill: troubleshooting playbook + issue draft, reading the
// diagnostics snapshot the app writes into the engine.

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundle ships SKILL.md only, managed and parseable', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, supportSkillName);
    expect(bundle.name, 'dsh-go-support');
    expect(bundle.files.keys, ['SKILL.md']);
    expect(bundle.skillMd.startsWith('---'), isTrue);
    expect(bundle.skillMd, contains('# dsh-go:managed'));
    expect(bundle.skillMd, contains('name: dsh-go-support'));
  });

  test('it points at the diagnostics file and covers the playbook', () async {
    final bundle = await loadUiSkillBundle(readAssetFromDisk, supportSkillName);
    final skill = bundle.skillMd;
    // Where the facts are, for both launch modes.
    expect(skill, contains('dsh-app/diagnostics.md'));
    // Symptoms the person actually reports.
    for (final topic in ['卡顿', '发热', '连不上', '安全模式', '更新装不上', '插件', '手机操控']) {
      expect(skill, contains(topic), reason: topic);
    }
    // It must produce an issue draft and respect privacy.
    expect(skill, contains('## 环境'));
    expect(skill, contains('复现步骤'));
    expect(skill, contains('隐私'));
  });
}
