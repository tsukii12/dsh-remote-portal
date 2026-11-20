// The SDK's `check` (sdk/plugin-kit/lib/view-check.js) is a line-by-line JavaScript twin of
// this app's plugin-view parser. Both read sdk/plugin-kit/test/parity/: the SDK test checks
// the twin against expected.json, this test checks the app against the same file. When the
// parser changes on purpose, change the twin the same way and regenerate expected.json
// (node sdk/plugin-kit/scripts/gen-parity.mjs) — a diff here means `check` would tell plugin
// authors something different from what the app's plugin details page shows.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Directory('${Directory.current.path}/../sdk/plugin-kit/test/parity');
  final skip = dir.existsSync() ? null : 'no sdk/ checkout next to app/';
  final inputs = skip != null ? const [] : jsonDecode(File('${dir.path}/inputs.json').readAsStringSync()) as List;
  final expected = skip != null ? const {} : jsonDecode(File('${dir.path}/expected.json').readAsStringSync()) as Map;

  PluginViewBudget budget(String name) => switch (name) {
    'toolCard' => PluginViewBudget.toolCard,
    'strip' => PluginViewBudget.strip,
    _ => PluginViewBudget.panel,
  };

  test('every case has an expectation', () {
    expect([for (final c in inputs) (c as Map)['name']], expected.keys.toList());
  }, skip: skip);

  for (final c in inputs) {
    final name = (c as Map)['name'] as String;
    test(name, () {
      final want = expected[name] as Map;
      final parse = parsePluginView(c['view'], data: c['data'], budget: budget(c['budget'] as String));
      final Map<String, Object?> got = switch (parse) {
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
      expect(got, {
        'fatal': want['fatal'],
        'title': want['title'],
        'issues': [
          for (final i in want['issues'] as List) {'path': (i as Map)['path'], 'message': i['message']},
        ],
      });
    }, skip: skip);
  }
}
