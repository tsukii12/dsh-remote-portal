// Goldens of the share-code sheets, light and dark:
//
//   flutter test --update-goldens test/share_code/share_code_golden_test.dart

import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/plugin_share_sheet.dart';
import 'package:dsh_app/ui/share_code/profile_share_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/fake_engine.dart';
import 'support/sheet_support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await _settle(tester);
}

ProfileShare _importProfile() => const ProfileShare(
  name: '写作配置',
  settings: {
    'subagent': {'maxDepth': 3, 'maxActiveSubagents': 4},
    'agent-default-model': {'model': 'deepseek-v4-pro'},
    'custom-lint-rules': {'strict': true},
  },
  plugins: [
    notesPlugin,
    SharedPlugin(
      name: 'dsh-writer',
      source: PluginSourceKind.github,
      spec: 'github:acme/dsh-writer#v2.0.0',
      title: '长文写作',
    ),
    SharedPlugin(
      name: '@deepseek-ai/dsh-experimental-session-titles-bundle',
      source: PluginSourceKind.official,
      title: '对话标题',
    ),
  ],
  presets: [SharedPreset(id: 'writer', name: '写作', bundle: '@acme/dsh-notes')],
  skills: [
    SharedSkill(name: 'outline', files: {'SKILL.md': '新的提纲技能'}),
    SharedSkill(name: 'weekly', files: {'SKILL.md': '按项目汇总。'}),
  ],
  agentsMd: '# 我的习惯\n回答用中文。\n',
);

FakeEngine _importEngine() => FakeEngine()
  ..addSettings('subagent', base: {'maxDepth': 1, 'maxActiveSubagents': 8})
  ..addSettings('agent-default-model', base: {'provider': 'deepseek', 'model': 'deepseek-v4-flash'})
  ..addBundle('@acme/dsh-notes', version: '1.2.0', source: '@acme/dsh-notes@1.2.0', title: '读书笔记')
  ..addBundle(
    '@deepseek-ai/dsh-experimental-session-titles-bundle',
    official: true,
    optional: true,
    enabled: false,
    installed: false,
    title: '对话标题',
  );

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('share-golden-'));
  tearDown(() => cache.deleteSync(recursive: true));

  goldenBoth(
    'share_plugin',
    () => SheetHost(open: (c) => showSharePluginSheet(c, plugin: notesPlugin, card: notesEntry)),
    overrides: () => shareOverrides(net: sampleNet(), out: RecordingShareOut(cache)),
    before: _open,
  );

  goldenBoth(
    'share_plugin_qr',
    () => SheetHost(open: (c) => showSharePluginSheet(c, plugin: notesPlugin)),
    overrides: () => shareOverrides(net: sampleNet(), out: RecordingShareOut(cache)),
    before: (tester) async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('share-code-qr')));
      await _settle(tester);
    },
  );

  ProfileExportSource? source;
  GuestFs? fs;
  Future<void> loadSource(WidgetTester tester) async {
    await tester.runAsync(() async {
      fs = sampleGuest();
      source = await loadProfileExport(DshClient.withCarrier(exportEngine()), hostLabel: '本机', isLocal: true, fs: fs);
    });
    addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
  }

  for (final mode in ['light', 'dark']) {
    final brightness = mode == 'dark' ? Brightness.dark : Brightness.light;

    testWidgets('share_profile_checklist ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      await loadSource(tester);
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: showShareProfileSheet),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), out: RecordingShareOut(cache), export: source),
        ),
      );
      await _open(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_profile_checklist_$mode.png'));
    });

    testWidgets('share_profile_preview ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      await loadSource(tester);
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: showShareProfileSheet),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), out: RecordingShareOut(cache), export: source),
        ),
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('share-profile-next')));
      await _settle(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_profile_preview_$mode.png'));
    });

    testWidgets('share_profile_file ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      await loadSource(tester);
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: (c) => showSharePluginSheetLarge(c)),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), out: RecordingShareOut(cache)),
        ),
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('share-code-gist')));
      await _settle(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/share_profile_file_$mode.png'));
    });

    testWidgets('import_plugin ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      usePhoneSurface(tester);
      final client = DshClient.withCarrier(FakeEngine());
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: (c) => showShareImportSheet(c, const PluginShare(notesPlugin))),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), targets: [localTarget(client)]),
        ),
      );
      await _open(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/import_plugin_$mode.png'));
    });

    testWidgets('import_profile ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      usePhoneSurface(tester);
      late GuestFs guest;
      await tester.runAsync(() async => guest = sampleGuest(existingOutline: true));
      addTearDown(() => guest.root.parent.deleteSync(recursive: true));
      final local = DshClient.withCarrier(_importEngine());
      final remote = DshClient.withCarrier(_importEngine());
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: (c) => showShareImportSheet(c, _importProfile())),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), targets: [localTarget(local), remoteTarget(remote)], fs: guest),
        ),
      );
      await _open(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/import_profile_$mode.png'));
    });

    testWidgets('import_profile_done ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      usePhoneSurface(tester);
      late GuestFs guest;
      await tester.runAsync(() async => guest = sampleGuest(existingOutline: true));
      addTearDown(() => guest.root.parent.deleteSync(recursive: true));
      final engine = _importEngine()
        ..restartRequired = true
        ..failInstall['github:acme/dsh-writer#v2.0.0'] = 'network';
      await tester.pumpWidget(
        goldenApp(
          home: SheetHost(open: (c) => showShareImportSheet(c, _importProfile())),
          brightness: brightness,
          overrides: shareOverrides(net: sampleNet(), targets: [localTarget(DshClient.withCarrier(engine))], fs: guest),
        ),
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('share-import-primary')));
      await _settle(tester);
      await tester.drag(find.byType(ListView).last, const Offset(0, -400));
      await _settle(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/import_profile_done_$mode.png'));
    });
  }
}

/// A profile too large for a link: the file state of the panel.
Future<void> showSharePluginSheetLarge(BuildContext context) {
  final big = ProfileShare(
    skills: [
      for (var i = 0; i < 4; i++)
        SharedSkill(
          name: 'skill-$i',
          files: {
            'SKILL.md': [for (var j = 0; j < 120; j++) '第 $j 行：${'内容不重复的说明 $i-$j ' * 2}'].join('\n'),
          },
        ),
    ],
  );
  return showProfileSharePreview(context, big);
}
