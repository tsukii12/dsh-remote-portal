import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../chat/support/harness.dart';
import 'memory_workspace.dart';

export 'memory_workspace.dart';

/// Overrides that put [workspace] behind the 文件 page and previews.
List<Override> workspaceOverrides(MemoryWorkspace workspace, {bool knownRoot = true, HostConnection? connection}) => [
  workspaceSourceProvider.overrideWith((ref, id) => workspace),
  workspaceRootProvider.overrideWith((ref, id) => knownRoot ? workspace.root : null),
  activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection ?? fakeConnection)),
  artifactThumbnailProvider.overrideWith((ref, key) async => null),
];

/// [home] in the test app, with [workspace] behind it.
Widget filesApp(
  Widget home,
  MemoryWorkspace workspace, {
  Brightness brightness = Brightness.light,
  bool knownRoot = true,
  HostConnection? connection,
  List<Override> overrides = const [],
}) => testApp(
  home,
  brightness: brightness,
  overrides: [
    ...workspaceOverrides(workspace, knownRoot: knownRoot, connection: connection),
    ...overrides,
  ],
);

/// A small project used by the page tests and goldens.
MemoryWorkspace sampleWorkspace() => MemoryWorkspace(
  files: {
    'README.md': '# 登录演示\n\n一个最小的 Flutter 登录页。\n\n## 运行\n\nflutter pub get\nflutter run\n',
    'pubspec.yaml': 'name: login_demo\nversion: 1.0.0\n',
    '.gitignore': 'build/\n.dart_tool/\n',
    'lib/main.dart': "import 'package:flutter/material.dart';\n\nvoid main() => runApp(const App());\n",
    'lib/login_page.dart': 'class LoginPage {}\n',
    'test/login_test.dart': 'void main() {}\n',
    'out/销售报告.pdf': '%PDF-1.7',
    'out/sales.csv': '地区,一月,二月\n华东,120,132\n华南,98,101\n',
    'out/chart.png': 'png',
    'notes 2.txt': 'two',
    'notes 10.txt': 'ten',
  },
  folders: {'assets'},
);
