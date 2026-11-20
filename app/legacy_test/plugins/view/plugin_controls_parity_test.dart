import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Directory('../sdk/plugin-kit/test/parity');
  final inputs = jsonDecode(File('${dir.path}/controls-inputs.json').readAsStringSync()) as List;
  final expected = jsonDecode(File('${dir.path}/controls-expected.json').readAsStringSync()) as Map;
  for (final c in inputs.cast<Map>()) {
    test('v2 parity: ${c['name']}', () {
      final budget = switch (c['budget']) {
        'toolCard' => PluginViewBudget.toolCard,
        'strip' => PluginViewBudget.strip,
        _ => PluginViewBudget.panel,
      };
      final result = parsePluginView(c['view'], data: c['data'], budget: budget);
      final got = switch (result) {
        DshUiInvalid(:final error) => {
          'fatal': true,
          'title': null,
          'issues': [
            {'path': error.path, 'message': error.message},
          ],
        },
        DshUiParsed(:final view) => {
          'fatal': false,
          'title': view.title,
          'issues': [
            for (final i in view.issues) {'path': i.path, 'message': i.message},
          ],
        },
      };
      expect(got, expected[c['name']]);
    });
  }
}
