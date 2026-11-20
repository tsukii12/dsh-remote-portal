import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final kit = Directory('../sdk/plugin-kit');
  test('App and SDK agree on v2 diagnostics and 256 quantised colour corrections', () {
    final process = Process.runSync('node', ['${kit.path}/test/style-parity.mjs']);
    expect(process.exitCode, 0, reason: '${process.stderr}');
    final expected = jsonDecode(process.stdout as String) as Map;
    final inputs = jsonDecode(File('${kit.path}/test/parity/style-inputs.json').readAsStringSync()) as List;
    final results = <Map<String, Object?>>[];
    for (final c in inputs.cast<Map>()) {
      final budget = PluginViewBudget.values.byName(c['budget'] as String);
      final parsed = parsePluginView(c['view'], data: c['data'], budget: budget);
      results.add(switch (parsed) {
        DshUiInvalid(:final error) => {
          'name': c['name'],
          'fatal': true,
          'title': null,
          'issues': [
            {'path': error.path, 'message': error.message},
          ],
        },
        DshUiParsed(:final view) => {
          'name': c['name'],
          'fatal': false,
          'title': view.title,
          'issues': [
            for (final issue in view.issues) {'path': issue.path, 'message': issue.message},
          ],
        },
      });
    }
    expect(results, expected['cases']);
    for (final c in (expected['colors'] as List).cast<Map>()) {
      expect(dshUiReadableColor(c['input'] as int, c['background'] as int), c['corrected']);
    }
  }, skip: kit.existsSync() ? null : 'Requires the SDK checkout and Node.js.');
}
