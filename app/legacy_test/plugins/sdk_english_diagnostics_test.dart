// Compare the two real parsers live, including generated English plurals.
// No generated expectation file is changed by this test.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kit = Directory('${Directory.current.path}/../sdk/plugin-kit');
  final inputs = File('${kit.path}/test/parity/inputs.json');
  final skip = inputs.existsSync() ? null : 'no sdk/ checkout next to app/';

  test('live English SDK diagnostic text matches the App parser for the shared corpus', () async {
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final cases = jsonDecode(inputs.readAsStringSync()) as List;
    late final ProcessResult node;
    try {
      node = await Process.run('node', [
        '--input-type=module',
        '-e',
        r'''import fs from 'node:fs';
const { checkView } = await import(process.argv[1]);
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
process.stdout.write(JSON.stringify(cases.map(c => ({name:c.name, ...checkView(c.view, {budget:c.budget, data:c.data, lang:'en'})}))));''',
        Uri.file('${kit.path}/lib/view-check.js').toString(),
        inputs.path,
      ]);
    } on ProcessException catch (error) {
      // ENOENT: this optional cross-runtime check needs a Node executable.
      // Permission errors and a Node process that starts but fails stay errors.
      if (error.errorCode != 2) rethrow;
      markTestSkipped('Node.js executable "node" is unavailable on PATH; live SDK/App parity needs Node.');
      return;
    }
    expect(node.exitCode, 0, reason: '${node.stderr}');
    final reports = jsonDecode(node.stdout as String) as List;
    expect(reports.length, cases.length);
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i] as Map;
      final js = reports[i] as Map;
      final parsed = parsePluginView(
        c['view'],
        data: c['data'],
        budget: PluginViewBudget.values.byName(c['budget'] as String),
      );
      final issues = switch (parsed) {
        DshUiParsed(:final view) => view.issues,
        DshUiInvalid(:final error) => [error],
      };
      expect(parsed is DshUiInvalid, js['fatal'], reason: c['name'] as String);
      expect(
        [
          for (final issue in issues) {'path': issue.path, 'message': issue.message},
        ],
        [
          for (final issue in js['issues'] as List) {'path': (issue as Map)['path'], 'message': issue['message']},
        ],
        reason: c['name'] as String,
      );
    }
  }, skip: skip);
}
