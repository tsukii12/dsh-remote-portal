import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:dsh_tavern/src/regex/regex_engine.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/regex-oracle.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (fixture['cases']! as List).cast<Map<String, Object?>>();
  for (final testCase in cases) {
    test('fixed ST regex: ${testCase['name']}', () {
      final expected = testCase['expected']! as Map<String, Object?>;
      final events = <Map<String, Object?>>[];
      var counter = 0;
      String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
        events.add({'text': text, 'characterOverride': characterOverride, 'postProcess': postProcess != null});
        return text.replaceAllMapped(RegExp(r'\{\{([a-z]+)\}\}', caseSensitive: false), (match) {
          final name = match[1]!.toLowerCase();
          final macros = (testCase['macros'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
          final values = <String, Object?>{'user': 'User', 'char': 'Character', ...macros};
          if (characterOverride != null) values['char'] = characterOverride;
          if (name != 'inc' && !values.containsKey(name)) return match[0]!;
          final value = name == 'inc' ? '${++counter}' : values[name];
          return (postProcess == null ? value : postProcess(value)).toString();
        });
      }

      final scripts = RegexEngine.readScripts(testCase['global']);
      final engine = RegexEngine(
        globalScripts: scripts,
        presetScripts: RegexEngine.readScripts(testCase['preset']),
        characterScripts: RegexEngine.readScripts(testCase['character']),
        enabled: testCase['enabled'] != false,
      );
      String execute() {
        final input = testCase['input']! as String;
        final characterOverride = testCase['characterOverride'] as String?;
        if (testCase['direct'] == true) {
          return engine.runScript(scripts.first, input, characterOverride: characterOverride, expand: expand);
        }
        return engine.apply(
          input,
          placement: (testCase['placement'] as num? ?? 1).toInt(),
          phase: RegexPhase.values.byName(testCase['phase'] as String? ?? 'writeBack'),
          isEdit: testCase['isEdit'] == true,
          depth: testCase['depth'] as num?,
          characterOverride: characterOverride,
          expand: expand,
        );
      }

      if (expected.containsKey('error')) {
        expect(
          execute,
          throwsA(
            isA<StateError>().having((error) => error.message, 'message', allOf(contains('fixture'), contains(r'$'))),
          ),
        );
      } else {
        expect(execute(), expected['output']);
      }
      expect(counter, expected['counter']);
      expect(events, expected['events']);
    });
  }

  test('script and source arrays are snapshots and migrations leave original JSON untouched', () {
    final placements = <Object?>[0, 1];
    final trims = <String>['a'];
    final original = <String, Object?>{
      'findRegex': '(a)',
      'replaceString': r'$1',
      'placement': placements,
      'trimStrings': trims,
      'unknown': {'preserve': true},
    };
    final before = jsonEncode(original);
    final script = RegexScript.fromJson(original);
    final scripts = <RegexScript>[script];
    final engine = RegexEngine(globalScripts: scripts);
    expect(jsonEncode(original), before);
    expect(script.placement, [1]);
    expect(script.markdownOnly, isTrue);
    expect(script.promptOnly, isTrue);
    placements.clear();
    trims.clear();
    scripts.clear();
    expect(engine.apply('a', placement: 1, phase: RegexPhase.prompt), '');
    expect(() => script.trimStrings.add('x'), throwsUnsupportedError);
    expect(() => script.placement.clear(), throwsUnsupportedError);
  });

  test('malformed known fields are skipped without deleting input or changing raw JSON', () {
    final raw = <Object?>[
      null,
      'not a script',
      {1: 'not a JSON key'},
      {
        'findRegex': 1,
        'replaceString': '',
        'placement': [1],
      },
      {
        'findRegex': 'x',
        'replaceString': 1,
        'placement': [1],
      },
      {
        'findRegex': 'x',
        'replaceString': '',
        'placement': [1],
        'trimStrings': [1],
      },
      {'findRegex': 'x', 'replaceString': 'Y', 'placement': '1'},
    ];
    final scripts = RegexEngine.readScripts(raw);
    expect(scripts, hasLength(4));
    expect(RegexEngine(globalScripts: scripts).apply('x', placement: 1), 'x');
    expect(RegexEngine.readScripts({'findRegex': 'x'}), isEmpty);
    expect(() => scripts.clear(), throwsUnsupportedError);
  });

  test('based regex numeric strings keep their value and syntax boundaries', () {
    // All three strings denote exact binary64 2^63; no product parser builds the oracle.
    const huge = 9223372036854775808.0;
    const literals = [
      '0x8000000000000000',
      '0b1000000000000000000000000000000000000000000000000000000000000000',
      '0o1000000000000000000000',
    ];
    for (final literal in literals) {
      final raw = <String, Object?>{
        'findRegex': 'A',
        'replaceString': 'B',
        'placement': [2],
        'markdownOnly': true,
        'promptOnly': true,
        'minDepth': literal,
        'maxDepth': literal,
        'substituteRegex': '0x2',
        'foreign': {'keep': null},
      };
      final before = jsonEncode(raw);
      final script = RegexScript.fromJson(raw);
      expect(script.minDepth, huge, reason: literal);
      expect(script.maxDepth, huge, reason: literal);
      expect(script.minDepth?.isFinite, isTrue);
      expect(script.maxDepth?.isFinite, isTrue);
      expect(script.substituteRegex, 2);
      final engine = RegexEngine(globalScripts: [script]);
      expect(engine.apply('A', placement: 2, phase: RegexPhase.prompt, depth: 0), 'A');
      expect(engine.apply('A', placement: 2, phase: RegexPhase.prompt, depth: huge), 'B');
      expect(engine.apply('A', placement: 2, phase: RegexPhase.prompt, depth: 18446744073709551616.0), 'A');
      expect(jsonEncode(raw), before);
    }

    for (final raw in const <Map<String, Object?>>[
      {},
      {'minDepth': null, 'maxDepth': null},
    ]) {
      final script = RegexScript.fromJson(raw);
      expect([script.minDepth, script.maxDepth], [null, null]);
    }
    final empty = RegexScript.fromJson({'minDepth': '', 'maxDepth': ''});
    expect([empty.minDepth, empty.maxDepth], [0, 0]);
    for (final invalid in ['+0x10', '-0b10', '0o8', '0x']) {
      final script = RegexScript.fromJson({'minDepth': invalid, 'maxDepth': invalid});
      expect(script.minDepth?.isNaN, isTrue, reason: invalid);
      expect(script.maxDepth?.isNaN, isTrue, reason: invalid);
    }
    final ordinary = RegexScript.fromJson({
      'findRegex': 'A',
      'replaceString': 'B',
      'placement': [2],
      'markdownOnly': false,
      'promptOnly': false,
      'minDepth': literals.first,
    });
    expect(RegexEngine(globalScripts: [ordinary]).apply('A', placement: 2, depth: 0), 'B');
  });

  test('expanded patterns are cached by expanded value without caching macro side effects', () {
    final script = _script(findRegex: '/{{user}}/g', substituteRegex: 2);
    final engine = RegexEngine(globalScripts: [script]);
    var user = 'x';
    var patternExpansions = 0;
    String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) {
      if (text == script.findRegex) patternExpansions++;
      final value = postProcess == null ? user : postProcess(user) as String;
      return text.replaceAll('{{user}}', value);
    }

    expect(engine.apply('x y', placement: 1, expand: expand), 'Y y');
    user = 'y';
    expect(engine.apply('x y', placement: 1, expand: expand), 'x Y');
    user = 'x';
    expect(engine.apply('x y', placement: 1, expand: expand), 'Y y');
    engine.clearCache();
    expect(engine.apply('x y', placement: 1, expand: expand), 'Y y');
    expect(patternExpansions, 4);
  });

  test('sanitizer preserves raw legacy values and only escapes string values', () {
    final values = <Object?>[
      null,
      true,
      false,
      1.25,
      ['x.y'],
      {'x': 'a.b'},
    ];
    for (final value in values) {
      expect(identical(RegexEngine.sanitizeRegexMacro(value), value), isTrue);
    }
    expect(RegexEngine.sanitizeRegexMacro('a-b.你😀'), r'a-b\.你😀');
    expect(RegexEngine.sanitizeRegexMacro('\n\r\t\u000b\f\x00/'), r'\n\r\t\v\f\0\/');
  });

  test('real new and legacy macro engines preserve raw numeric sanitizer difference', () {
    final context = MacroContext(localVariables: {'x': 1.25});
    final engine = RegexEngine(globalScripts: [_script(findRegex: r'^{{getvar::x}}$', substituteRegex: 2)]);
    String modern(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
        const MacroEngine().expand(text, context, postProcess: postProcess);
    String legacy(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
        const LegacyMacroEngine().expand(text, context, postProcess: postProcess);
    // Legacy passes 1.25 (a number) to the sanitizer, which leaves it alone.
    // The new engine passes "1.25", so its dot becomes a literal match.
    expect(engine.apply('1x25', placement: 1, expand: legacy), 'Y');
    expect(engine.apply('1x25', placement: 1, expand: modern), '1x25');
    expect(engine.apply('1.25', placement: 1, expand: modern), 'Y');
    expect(context.localVariables, {'x': 1.25});
  });

  test('real replacement macro evaluation mutates once per selected match', () {
    for (final legacy in [false, true]) {
      final context = MacroContext(localVariables: {'n': 0});
      final engine = RegexEngine(globalScripts: [_script(replaceString: r'{{incvar::n}}-$0')]);
      String expand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) => legacy
          ? const LegacyMacroEngine().expand(text, context, postProcess: postProcess)
          : const MacroEngine().expand(text, context, postProcess: postProcess);
      expect(engine.apply('xx', placement: 1, expand: expand), '1-x2-x');
      expect(context.localVariables['n'], equals(2));
      expect(engine.apply('xx', placement: 1, phase: RegexPhase.prompt, expand: expand), 'xx');
      expect(context.localVariables['n'], equals(2));
    }
  });
}

RegexScript _script({String findRegex = '/x/g', String replaceString = 'Y', Object? substituteRegex = 0}) =>
    RegexScript.fromJson({
      'findRegex': findRegex,
      'replaceString': replaceString,
      'placement': [1],
      'trimStrings': <String>[],
      'substituteRegex': substituteRegex,
    });
