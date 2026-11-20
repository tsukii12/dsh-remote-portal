import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';

void main() {
  for (final legacy in [false, true]) {
    final name = legacy ? 'legacy' : 'modern';
    String expand(
      String text,
      MacroContext context, {
      Map<String, String> overrides = const {},
      Object? Function(Object?)? postProcess,
      bool? replaceCharacterCard,
      String? characterOverride,
    }) => legacy
        ? const LegacyMacroEngine().expand(
            text,
            context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCharacterCard,
            characterOverride: characterOverride,
          )
        : const MacroEngine().expand(
            text,
            context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCharacterCard,
            characterOverride: characterOverride,
          );

    test('$name call-specific names reach nested fields and never change notChar or the context', () {
      final context = _context(card: {'description': '{{char}}/{{group}}/{{groupNotMuted}}/{{notChar}}'});
      const text = '{{user}}|<CHAR>|{{charIfNotGroup}}|{{groupNotMuted}}|{{notChar}}|{{description}}';
      expect(expand(text, context, characterOverride: 'X'), 'U|X|X|X|N|X/X/X/N');
      expect(expand(text, context), 'U|C|G|M|N|C/G/M/N');
      expect(expand(text, context, characterOverride: ''), 'U||||N|///N');
      expect(expand('{{char}}/{{group}}', context, characterOverride: 'X', overrides: {'char': 'mapped'}), 'mapped/X');
      expect([context.charName, context.group, context.groupNotMuted, context.notChar], ['C', 'G', 'M', 'N']);
    });

    test('$name per-call card mode overrides either context default without caching field effects', () {
      final local = <String, Object?>{'visits': 0};
      final card = <String, Object?>{'description': '{{incvar::visits}}<CHAR>'};
      final context = _context(local: local, card: card, original: 'O');
      const text = '{{description}}|{{original}}|{{original}}';
      expect(
        expand(text, context, replaceCharacterCard: false, characterOverride: 'X'),
        legacy ? '{{description}}|O|' : '|O|',
      );
      expect(local['visits'], 0);
      expect(expand(text, context, replaceCharacterCard: true, characterOverride: 'X'), '1X|O|');
      expect(expand(text, context), '2C|O|');
      final base = _context(local: local, card: card, replaceCharacterCard: false);
      expect(expand('{{description}}', base, replaceCharacterCard: true, characterOverride: 'Y'), '3Y');
      expect(expand('{{description}}', base), legacy ? '{{description}}' : '');
      expect(local['visits'], 3);
      expect(context.replaceCharacterCard, isTrue);
      expect(base.replaceCharacterCard, isFalse);
    });

    test('$name warm patterns bind current maps history original and postProcess on every call', () {
      final localA = <String, Object?>{'n': 0};
      final localB = <String, Object?>{'n': 40};
      final historyA = <MacroMessage>[const MacroMessage(text: 'old')];
      final a = _context(local: localA, history: historyA, userName: 'A', original: 'OA');
      final b = _context(
        local: localB,
        history: [const MacroMessage(text: 'new')],
        userName: 'B',
        original: 'OB',
      );
      const text = '{{user}}/{{incvar::n}}/{{lastMessage}}/{{original}}/{{original}}';
      expect(expand(text, a), 'A/1/old/OA/');
      expect(expand(text, b), 'B/41/new/OB/');
      historyA.add(const MacroMessage(text: 'appended'));
      expect(expand(text, a), 'A/2/appended/OA/');
      expect(localA['n'], 2);
      expect(localB['n'], 41);
      expect(expand('{{user}}', a, postProcess: (value) => 'first:$value'), 'first:A');
      expect(expand('{{user}}', b, postProcess: (value) => 'second:$value'), 'second:B');
    });

    test('$name reentrant calls keep their own character and card mode', () {
      final context = _context(card: {'description': '<CHAR>'});
      var entered = false;
      String? inner;
      final result = expand(
        '{{char}}|{{description}}',
        context,
        characterOverride: 'outer',
        postProcess: (value) {
          if (!entered) {
            entered = true;
            inner = expand(
              '{{char}}|{{description}}',
              context,
              characterOverride: 'inner',
              replaceCharacterCard: false,
            );
          }
          return value;
        },
      );
      expect(result, 'outer|outer');
      expect(inner, legacy ? 'inner|{{description}}' : 'inner|');
      expect(expand('{{char}}|{{description}}', context), 'C|C');
    });

    test('$name compiled-pattern reuse never caches random draws or one-shot original state', () {
      var draws = 0;
      final local = <String, Object?>{'n': 0};
      final context = _context(
        local: local,
        replaceCharacterCard: false,
        original: 'O',
        random: () => draws++ == 0 ? 0.0 : 0.99,
      );
      const text = '{{random::a::b}}/{{incvar::n}}/{{original}}/{{original}}';
      expect(expand(text, context), 'a/1/O/');
      expect(expand(text, context), 'b/2/O/');
      expect(draws, 2);
      expect(local['n'], 2);
    });
  }

  test('modern nested greetings and examples inherit only this call character override', () {
    final context = _context(
      card: {
        'first_mes': 'first <CHAR>',
        'alternate_greetings': ['alternate {{char}}'],
        'mes_example': '<START>\n{{char}}: hello',
      },
    );
    const text = '{{greeting}}|{{greeting::1}}|{{mesExamples}}';
    expect(
      const MacroEngine().expand(text, context, characterOverride: 'X'),
      'first X|alternate X|<START>\nX: hello\n',
    );
    expect(const MacroEngine().expand(text, context), 'first C|alternate C|<START>\nC: hello\n');
  });

  test('legacy nested example separator inherits character override while keeping its side effects fresh', () {
    const engine = LegacyMacroEngine(contextTemplate: {'example_separator': '{{setvar::separator::<CHAR>}}'});
    final local = <String, Object?>{};
    final context = _context(local: local, card: {'mes_example': '<START>\n<CHAR>: hello'});
    expect(engine.expand('{{mesExamples}}', context, characterOverride: 'X'), '<START>\nX: hello\n');
    expect(local['separator'], 'X');
    expect(engine.expand('{{mesExamples}}', context), '<START>\nC: hello\n');
    expect(local['separator'], 'C');
  });

  test('legacy cached dynamic names remain escaped and bind fresh replacement values', () {
    const engine = LegacyMacroEngine();
    final context = _context(replaceCharacterCard: false);
    const text = r'{{x.y}}/{{xay}}/{{a+b}}/{{aab}}/{{box[0]}}/{{box0}}';
    expect(
      engine.expand(text, context, overrides: {'x.y': 'A', 'a+b': 'B', 'box[0]': 'C'}),
      'A/{{xay}}/B/{{aab}}/C/{{box0}}',
    );
    expect(
      engine.expand(text, context, overrides: {'x.y': 'D', 'a+b': 'E', 'box[0]': 'F'}),
      'D/{{xay}}/E/{{aab}}/F/{{box0}}',
    );
  });

  test('legacy dynamic pattern churn does not retain evicted closures or stale overrides', () {
    const engine = LegacyMacroEngine();
    final context = _context(replaceCharacterCard: false);
    final overrides = <String, String>{for (var index = 0; index < 1100; index++) 'slot.$index': 'value-$index'};
    expect(engine.expand('{{slot.0}}/{{slot.1099}}', context, overrides: overrides), 'value-0/value-1099');
    expect(
      engine.expand(
        '{{slot.0}}/{{slot.1099}}',
        context,
        overrides: {'slot.0': 'fresh-first', 'slot.1099': 'fresh-last'},
      ),
      'fresh-first/fresh-last',
    );
    expect(engine.expand('{{slot.0}}', context), '{{slot.0}}');
  });
}

MacroContext _context({
  Map<String, Object?>? local,
  Map<String, Object?> card = const {},
  List<MacroMessage> history = const [],
  String userName = 'U',
  String? original,
  bool replaceCharacterCard = true,
  double Function()? random,
}) => MacroContext(
  localVariables: local,
  userName: userName,
  charName: 'C',
  group: 'G',
  groupNotMuted: 'M',
  notChar: 'N',
  card: card,
  history: history,
  original: original,
  replaceCharacterCard: replaceCharacterCard,
  chatId: 'cache-test',
  now: DateTime.utc(2024, 2, 29),
  timeZoneOffset: Duration.zero,
  random: random ?? () => 0,
);
