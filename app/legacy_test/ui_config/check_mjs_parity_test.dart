// The skill's zero-dependency checker against the same fixtures as the app's
// validator (parser_test.dart): same pointers, same words. Needs `node` on
// PATH; skipped without it.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String? _node() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    if (File('$dir/node').existsSync()) return '$dir/node';
  }
  return null;
}

void main() {
  final node = _node();
  final skip = node == null ? 'node is not installed' : null;
  final checker = '$appDir/assets/skills/dsh-go-ui/check.mjs';

  Future<ProcessResult> run(List<String> args, {Map<String, String>? env, String? stdin}) async {
    if (stdin == null) return Process.run(node!, [checker, ...args], environment: env);
    final process = await Process.start(node!, [checker, ...args], environment: env);
    process.stdin.write(stdin);
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    return ProcessResult(process.pid, await process.exitCode, out, err);
  }

  Map<String, Object?> json(ProcessResult r) {
    final map = jsonDecode(r.stdout as String) as Map<String, Object?>;
    return {...map}..remove('file');
  }

  group('check.mjs', () {
    for (final name in fixtureNames()) {
      test(name, () async {
        final r = await run([fixturePath(name), '--json']);
        expect(json(r), expected(name));
        expect(json(r), summarize(parseUiConfig(fixture(name))));
      }, skip: skip);
    }

    test('generated cases agree with the app', () async {
      final cases = [
        '{"version": 1, "x": "${'a' * (64 * 1024)}"}',
        '{"version": 1, "header": {"actions": [{"id": "x1", "icon": "bolt", "label": "\\u0000\\u2028", "action": {"type": "send", "text": "a"}}]}}',
        '{"version": 1, "composer": {"quickActions": [{"label": "x", "action": {"type": "send", "text": "${'字' * 2001}"}}]}}',
        '{"version": 1, "composer": {"quickActions": [{"label": "x", "action": {"type": "command", "name": "a", "args": "${'b' * 501}"}}]}}',
        '{"version": 1, "composer": {"quickActions": [{"label": "x", "action": {"type": "link", "url": "https://${'a' * 2000}.com"}}]}}',
        '{"version": 1, "plugins": {"seats": {"main": {"${'a' * 215}": "web"}}}}',
        '{"version": 99999, "density": "compact"}',
        '{"version": -1}',
        '{"version": 1, "density": "compact"} ',
        '{"version":1,"theme":{"accentPreset":"amber","accent":"#000000"}}',
        '{"version":1,"theme":{"accent":"#000000","accentPreset":"amber"}}',
        '{"version":1,"density":"${'长' * 40}"}',
      ];
      for (final text in cases) {
        final r = await run(['-', '--json'], stdin: text);
        expect(json(r), summarize(parseUiConfig(text)), reason: text.length > 120 ? text.substring(0, 120) : text);
      }
    }, skip: skip);

    test('exit codes and the human summary', () async {
      final dir = Directory.systemTemp.createTempSync('ui-check-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ok = File('${dir.path}/ok.json')..writeAsStringSync('{"version": 1, "density": "compact"}');
      final bad = File('${dir.path}/bad.json')..writeAsStringSync('{"version": 1, "density": "cozy"}');
      final broken = File('${dir.path}/broken.json')..writeAsStringSync('{"version": 1,}');

      final r0 = await run([ok.path]);
      expect(r0.exitCode, 0);
      expect(r0.stdout, 'ui.json：已应用 1 项\n');
      final r1 = await run([bad.path]);
      expect(r1.exitCode, 1);
      expect(r1.stdout, 'ui.json：已应用 0 项，1 处没生效\n错误 /density：不支持的值「cozy」，可选：compact、comfortable\n');
      final r2 = await run([broken.path]);
      expect(r2.exitCode, 2);
      expect(r2.stdout, 'ui.json 没有生效：第 1 行第 14 列：多余的逗号\n');
      final r3 = await run(['${dir.path}/missing.json']);
      expect(r3.exitCode, 3);
    }, skip: skip);

    test('finds ui.json from where the skill is installed, or from DSH_HOME', () async {
      final home = Directory.systemTemp.createTempSync('ui-check-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      final scripts = Directory('${home.path}/skills/dsh-go-ui/scripts')..createSync(recursive: true);
      File(checker).copySync('${scripts.path}/check.mjs');
      File('$appDir/assets/skills/dsh-go-ui/schema.json').copySync('${home.path}/skills/dsh-go-ui/schema.json');
      Directory('${home.path}/dsh-go').createSync();
      File('${home.path}/dsh-go/ui.json').writeAsStringSync('{"version": 1, "hide": ["whaleTail"]}');

      final env = {...Platform.environment}..remove('DSH_HOME');
      final installed = await Process.run(
        node!,
        ['${scripts.path}/check.mjs', '--json'],
        environment: env,
        includeParentEnvironment: false,
      );
      expect(installed.exitCode, 0, reason: '${installed.stderr}');
      expect((jsonDecode(installed.stdout as String) as Map)['file'], '${home.path}/dsh-go/ui.json');

      final viaEnv = await run(['--json'], env: {'DSH_HOME': home.path});
      expect((jsonDecode(viaEnv.stdout as String) as Map)['applied'], 1);
    }, skip: skip);
  });
}
