import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_formula.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final sample in [
    (name: 'array length is missing', data: '{"rows":[2,3]}', formula: 'data.rows.length', value: null),
    (name: 'array index is numeric', data: '{"rows":[2,3]}', formula: 'data.rows[0]', value: 2.0),
    (name: 'object length is a field', data: '{"rows":{"length":2}}', formula: 'data.rows.length', value: 2.0),
  ]) {
    test(sample.name, () {
      final data = jsonDecode(sample.data);
      final source = jsonDecode(
        jsonEncode({
          'v': 2,
          'type': 'metric',
          'label': 'Count',
          'value': {'=': sample.formula},
        }),
      );
      final number = evaluateDshUiFormula(sample.formula, data);
      expect(number, sample.value);

      // Exercise the public consumer entry used by plugin views, including
      // formula resolution, missing-value rendering and parser diagnostics.
      final result = parsePluginView(source, data: data);
      expect(result, isA<DshUiParsed>());
      final parsed = (result as DshUiParsed).view;
      final metric = parsed.root as DshUiMetric;
      expect(metric.label, 'Count');
      expect(metric.value, sample.value == null ? '—' : '2');
      final formulaIssues = parsed.issues.where((issue) => issue.message == appL10n.plugInputFormula).toList();
      expect(formulaIssues.map((issue) => issue.path), sample.value == null ? ['view.value'] : isEmpty);
      debugPrint(
        jsonEncode({
          'case': sample.name,
          'data': data,
          'view': source,
          'evaluated': number,
          'metric': metric.value,
          'issues': [
            for (final issue in parsed.issues) {'path': issue.path, 'message': issue.message},
          ],
        }),
      );
    });
  }
}
