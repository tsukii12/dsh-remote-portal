import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';

// Regression for ECMAScript numeric conversion of stored Unicode strings.
// Expected values come from the actual fixed ST variables.js functions in the
// companion V8 source probe. The context values deliberately bypass literal
// macro-argument trimming so these cases isolate JS-number conversion.
void main() {
  const modern = MacroEngine();
  const legacy = LegacyMacroEngine();
  const samples = <({String name, String value, String getOutput, String incOutput, Object afterInc})>[
    (
      name: 'NEL around 1',
      value: '\u00851\u0085',
      getOutput: '\u00851\u0085',
      incOutput: '\u00851\u00851',
      afterInc: '\u00851\u00851',
    ),
    (
      name: 'NEL around 0',
      value: '\u00850\u0085',
      getOutput: '\u00850\u0085',
      incOutput: '\u00850\u00851',
      afterInc: '\u00850\u00851',
    ),
    (name: 'NEL only', value: '\u0085', getOutput: '\u0085', incOutput: '\u00851', afterInc: '\u00851'),
    (name: 'NBSP around 1', value: '\u00a01\u00a0', getOutput: '1', incOutput: '2', afterInc: 2),
    (name: 'BOM around 1', value: '\ufeff1\ufeff', getOutput: '1', incOutput: '2', afterInc: 2),
    (name: 'NBSP only', value: '\u00a0', getOutput: '\u00a0', incOutput: '1', afterInc: 1),
    (name: 'BOM only', value: '\ufeff', getOutput: '\ufeff', incOutput: '1', afterInc: 1),
    (
      name: 'NEL inside digits',
      value: '1\u00852',
      getOutput: '1\u00852',
      incOutput: '1\u008521',
      afterInc: '1\u008521',
    ),
  ];

  for (final mode in ['modern', 'legacy']) {
    for (final global in [false, true]) {
      final suffix = global ? 'globalvar' : 'var';
      for (final sample in samples) {
        test('$mode / $suffix / ${sample.name}', () {
          final localVariables = <String, Object?>{'x': 'other-scope'};
          final globalVariables = <String, Object?>{'x': 'other-scope'};
          final variables = global ? globalVariables : localVariables;
          final otherVariables = global ? localVariables : globalVariables;
          variables['x'] = sample.value;
          final context = MacroContext(
            localVariables: localVariables,
            globalVariables: globalVariables,
            chatId: 'unicode-number-fixture',
            now: DateTime.utc(2026, 11, 10, 12),
          );
          String expand(String input) =>
              mode == 'modern' ? modern.expand(input, context) : legacy.expand(input, context);

          expect(expand('{{get$suffix::x}}'), sample.getOutput);
          expect(variables['x'], sample.value, reason: 'Reading must retain the original stored value.');
          expect(expand('{{inc$suffix::x}}'), sample.incOutput);
          expect(variables['x'], sample.afterInc);
          expect(otherVariables, {'x': 'other-scope'});
        });
      }
    }
  }
}
