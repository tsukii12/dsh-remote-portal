// Shared fixtures for the share-code sheet tests and goldens.

import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/share_code/share_out.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'package:dsh_app/state/plugins_state.dart' show MarketEntry;

import 'fake_engine.dart';

const notesIntegrity =
    'sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==';

const notesPlugin = SharedPlugin(
  name: '@acme/dsh-notes',
  source: PluginSourceKind.npm,
  spec: '@acme/dsh-notes@1.4.2',
  version: '1.4.2',
  integrity: notesIntegrity,
  title: '读书笔记',
  author: 'Acme 工作室',
  summary: '把对话整理成读书笔记，按章节归档',
);

/// The market's entry for [notesPlugin]: its picture card.
final notesEntry = MarketEntry(
  MarketPlugin(
    name: '@acme/dsh-notes',
    author: 'Acme 工作室',
    sortKeys: const {'stars': 128},
    versions: [MarketVersion(version: '1.4.2', published: DateTime.utc(2026, 10, 12), source: const MarketNpmSource())],
  ),
  webOnly: false,
  categoryTitle: null,
);

FakeShareNet sampleNet() => FakeShareNet()
  ..npm['@acme/dsh-notes@1.4.2'] = const NpmFacts(integrity: notesIntegrity, publisher: 'acme', unpackedSize: 48210);

/// The engine a profile is exported from.
FakeEngine exportEngine() {
  final e = FakeEngine()
    ..addSettings('agent-default-model', base: {'provider': 'deepseek'}, user: {'model': 'deepseek-v4-pro'})
    ..addSettings('subagent', base: {'maxDepth': 1}, user: {'maxDepth': 3, 'maxActiveSubagents': 4})
    ..addSettings('web-search-deepseek', user: {'apiKeyEnv': 'DEEPSEEK_API_KEY', 'maxUses': 8})
    ..addSettings('custom-lint-rules', user: {'strict': true})
    ..addBundle(
      '@acme/dsh-notes',
      version: '1.4.2',
      source: '@acme/dsh-notes@^1.4.0',
      title: '读书笔记',
      rows: [
        {'rowId': 'preset-writer', 'moduleName': agentPresetModule},
      ],
    )
    ..addBundle('dsh-writer', version: '2.0.0', source: 'github:acme/dsh-writer#v2.0.0', title: '长文写作')
    ..addBundle('my-tools', version: '0.0.1', source: '/root/plugins/my-tools', title: '我的工具')
    ..addBundle(
      '@deepseek-ai/dsh-experimental-session-titles-bundle',
      official: true,
      optional: true,
      enabled: true,
      installed: false,
      title: '对话标题',
    );
  e.presets.add({'id': 'writer', 'name': '写作'});
  return e;
}

GuestFs sampleGuest({bool existingOutline = false}) {
  final fs = tempGuest();
  writeGuest(
    fs,
    '/root/.dsh/skills/outline/SKILL.md',
    existingOutline ? '旧的提纲技能' : '---\nname: outline\ndescription: 先列提纲再动笔\n---\n先列提纲。',
  );
  writeGuest(fs, '/root/.dsh/skills/weekly.md', '---\nname: weekly\ndescription: 生成周报\n---\n按项目汇总。');
  writeGuest(fs, '/root/.agents/AGENTS.md', '# 我的习惯\n回答用中文。\n先给结论。\n');
  return fs;
}

/// Records instead of sharing.
class RecordingShareOut extends ShareOut {
  RecordingShareOut(Directory cache)
    : super(files: const FilesChannel(), cacheRoot: () async => cache, clock: () => DateTime(2026, 10, 24, 9, 30));

  final copied = <String>[];
  final sharedText = <String>[];
  final sharedFiles = <String>[];
  final saved = <String>[];

  @override
  Future<void> copy(String text) async => copied.add(text);

  @override
  Future<void> shareText(String text) async => sharedText.add(text);

  @override
  Future<File> write(String name, String content) async {
    final f = File('${Directory.systemTemp.path}/$name');
    f.writeAsStringSync(content);
    return f;
  }

  @override
  Future<void> shareFile(File file, {String? text}) async => sharedFiles.add(file.path);

  @override
  Future<String> save(String name, String content) async {
    final file = await write(name, content);
    saved.add(file.path);
    return 'Download/DSH-Go/$name';
  }
}

ImportTarget localTarget(DshClient client) =>
    ImportTarget(HostConnection(hostId: '', client: client, label: '本机', isLocal: true), isActive: false);

ImportTarget remoteTarget(DshClient client) => ImportTarget(
  HostConnection(client: client, label: '书房的 Mac · SSH', isLocal: false, kind: HostKind.portal, hostId: 'mac'),
  isActive: true,
);

List<Override> shareOverrides({
  required ShareNet net,
  ShareOut? out,
  List<ImportTarget> targets = const [],
  GuestFs? fs,
  ProfileExportSource? export,
}) => [
  shareNetProvider.overrideWithValue(net),
  if (out != null) shareOutProvider.overrideWithValue(out),
  importTargetsProvider.overrideWithValue(targets),
  // The fake targets aren't the app's active host: straight to their client.
  pluginRunnerFactoryProvider.overrideWithValue((_, t) => DirectPluginRunner(t.client, isLocal: t.isLocal)),
  guestFsProvider.overrideWith((ref) async => fs),
  if (export != null) profileExportProvider.overrideWith((ref) async => export),
];

/// A page behind the sheet: the app backdrop and a button that opens it.
class SheetHost extends StatelessWidget {
  const SheetHost({super.key, required this.open});

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => AppBackdrop(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Builder(
          builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open')),
        ),
      ),
    ),
  );
}
