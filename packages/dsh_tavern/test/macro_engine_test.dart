import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = MacroEngine();
  MacroContext context({
    Map<String, Object?>? local,
    Map<String, Object?>? global,
    Map<String, Object?> card = const {},
    double Function()? random,
  }) => MacroContext(
    userName: 'U',
    charName: 'C',
    localVariables: local,
    globalVariables: global,
    card: card,
    now: DateTime.utc(2024, 2, 29, 18, 7, 8, 123),
    timeZoneOffset: Duration.zero,
    random: random ?? () => 0.5,
  );
  String expand(String text) => engine.expand(text, context());

  group('AST and evaluation order', () {
    test('names, case, legacy markers, and nested arguments', () {
      expect(expand('{{USER}}/<bot>/<CHAR>/<group>/<charIfNotGroup>'), 'U/C/C/C/C');
      expect(expand('{{reverse::x{{user}}😀}}'), '😀Ux');
      expect(expand('{{unknown :: {{user}} :: tail }}'), '{{unknown :: U :: tail }}');
      expect(expand('{{user::{{char}}}}'), '{{user::C}}');
      expect(expand('{{getvar::missing}}'), '');
    });

    test('only leading double colon splits multiple arguments', () {
      expect(expand('{{reverse a b}}'), 'b a');
      expect(expand('{{reverse:a::b}}'), 'b::a');
      expect(expand('{{reverse::a::b}}'), '{{reverse::a::b}}');
      expect(expand('{{reverse::"ab"}}'), '"ba"');
      expect(expand('{{reverse::a|b}}'), 'b|a');
      expect(expand('{{space::0}}X{{newline::2}}'), 'X\n\n');
      expect(expand('{{space::+2}}'), '{{space::+2}}');
      expect(expand('{{space::-1}}'), '{{space::-1}}');
      expect(expand('{{space::{{space}}2{{space}}}}'), '  ');
    });

    test('wrong arity retains outer call after nested side effects', () {
      final local = <String, Object?>{};
      expect(engine.expand('{{reverse::{{incvar::x}}::b}}', context(local: local)), '{{reverse::1::b}}');
      expect(local, {'x': 1});
    });

    test('returned macro syntax is not evaluated a second time', () {
      final c = context(local: {'literal': '{{user}}'});
      expect(engine.expand('{{getvar::literal}}', c), '{{user}}');
      expect(engine.expand('{{future}}', c, overrides: {'future': '{{char}}'}), '{{char}}');
    });

    test('scopes trim and dedent by first nonempty line', () {
      expect(expand('{{trim}}\n    first\n      second\n  last\n{{/trim}}'), 'first\n  second\nlast');
      expect(expand('{{#trim}}\n  keep\n{{/trim}}'), '\n  keep\n');
      expect(expand('{{reverse}}\n  abc\n{{/reverse}}'), 'cba');
      expect(expand('{{reverse}}{{/reverse}}'), '');
      expect(expand('{{user}}text{{/user}}'), '{{user}}text{{/user}}');
      expect(expand('{{/reverse}}'), '{{/reverse}}');
      expect(expand('{{! ? ~ > user}}'), 'U');
    });

    test('nested same-name scopes and filled inline calls pair correctly', () {
      expect(expand('{{reverse}}A{{reverse}}bc{{/reverse}}D{{/reverse}}'), 'DbcA');
      expect(expand('{{if true}}a{{if::true::b}}c{{/if}}'), 'abc');
      expect(
        expand(
          '{{if true}}A{{if false}}B{{else}}C{{/if}}D'
          '{{else}}E{{/if}}',
        ),
        'ACD',
      );
    });

    test('unknown scoped fallback follows fixed ST rawInner reconstruction', () {
      // This surprising closing-brace result is derived from ST's scoped
      // argument entry being outside the opening macro's inner range.
      expect(expand('{{unknown}}x{{user}}{{/unknown}}'), '{{unknown}}xU}}');
      expect(expand('{{unknown}}{{/unknown}}'), '{{unknown}}');
    });

    test('comments evaluate nested arguments and scoped comments', () {
      final local = <String, Object?>{};
      final c = context(local: local);
      expect(engine.expand('a{{// {{incvar::x}}}}b{{//}}c{{user}}{{///}}d', c), 'abd');
      expect(local['x'], 1);
      expect(expand('{{//}}'), '{{//}}');
      expect(expand('{{comment::a::b}}'), '{{comment::a::b}}');
    });

    test('escaped braces, surplus braces, incomplete outer call, legacy trim', () {
      expect(expand(r'\{\{user\}\} {{user}}'), '{{user}} U');
      expect(expand('{{{user}}}'), '{U}');
      expect(expand('{{unknown {{user}}'), '{{unknown U');
      expect(expand('a\n\r\n{{trim}}\n\nb'), 'ab');
      expect(expand('a {{trim}} b{{else}}'), 'a  b');
    });

    test('dynamic overrides are case insensitive, zero-argument definitions', () {
      final c = context();
      expect(engine.expand('{{USER}}/{{extra}}', c, overrides: {'user': 'X', 'EXTRA': 'Y'}), 'X/Y');
      expect(engine.expand('{{reverse::{{user}}}}', c, overrides: {'reverse': 'X'}), '{{reverse::U}}');
    });
  });

  group('lazy if and variable expressions', () {
    test('variable scope prefixes allow ST whitespace before the name', () {
      for (final scope in ['.', r'$']) {
        for (final padding in [' ', '\t', '\n', ' \t\r\n ']) {
          final local = <String, Object?>{};
          final global = <String, Object?>{};
          final c = context(local: local, global: global);
          expect(engine.expand('{{$scope${padding}x = A}}{{$scope${padding}x}}', c), 'A');
          expect(scope == '.' ? local : global, {'x': 'A'});
          expect(scope == '.' ? global : local, isEmpty);
        }
      }
    });

    test('unselected branches cause neither writes nor random draws', () {
      var draws = 0;
      final local = <String, Object?>{};
      final c = context(
        local: local,
        random: () {
          draws++;
          return 0;
        },
      );
      expect(
        engine.expand(
          '{{if false}}{{incvar::bad}}{{random::x::y}}'
          '{{else}}{{incvar::ok}}{{/if}}',
          c,
        ),
        '1',
      );
      expect(engine.expand('{{if::0::{{incvar::bad}}}}', c), '');
      expect(local, {'ok': 1});
      expect(draws, 0);
    });

    test('false words, inversion, shorthand and bare registered names', () {
      final c = MacroContext(
        userName: '',
        localVariables: {'yes': '1'},
        globalVariables: {'no': 'off'},
        random: () => 0,
      );
      for (final word in ['', 'false', 'FALSE', 'off', '0']) {
        expect(engine.expand('{{if::$word::yes{{else}}no}}', c), 'no');
      }
      expect(engine.expand('{{if !off}}yes{{/if}}', c), 'yes');
      expect(engine.expand('{{if user}}bad{{else}}empty{{/if}}', c), 'empty');
      expect(engine.expand('{{if .yes}}local{{/if}}', c), 'local');
      expect(engine.expand(r'{{if $no}}bad{{else}}global{{/if}}', c), 'global');
      expect(engine.expand('{{if::{{space}}::space is truthy}}', c), 'space is truthy');
      expect(engine.expand('{{if::{{inverted}}::literal}}', c, overrides: {'inverted': '!off'}), 'literal');
    });

    test('if preserves selected whitespace only with hash flag', () {
      expect(expand('{{if true}}\n    A\n      B\n{{/if}}'), 'A\n  B');
      expect(expand('{{#if true}}\n  A\n{{else}}\n  B\n{{/if}}'), '\n  A\n');
      expect(expand('{{#if false}}\n  A\n{{else}}\n  B\n{{/if}}'), '\n  B\n');
    });

    test('all arithmetic operators and local/global separation', () {
      final local = <String, Object?>{};
      final global = <String, Object?>{};
      final c = context(local: local, global: global);
      expect(
        engine.expand(
          r'{{.x = 003}}{{.x += 2}}{{.x++}}|'
          r'{{.x--}}|{{.x -= 2}}{{.x}}|{{$x = global}}{{$x}}',
          c,
        ),
        '6|5|3|global',
      );
      expect(local, {'x': 3});
      expect(global, {'x': 'global'});
      expect(engine.expand('{{.x -= nope}}{{.x}}', c), '3');
      expect(engine.expand('{{.my-long-name = ok}}{{.my-long-name}}', c), 'ok');
    });

    test('fallback operators are lazy and distinguish absence from falsity', () {
      final local = <String, Object?>{'zero': '0', 'nil': null, 'yes': 'Y'};
      final c = context(local: local);
      expect(
        engine.expand(
          '{{.yes || {{incvar::bad}}}}|'
          '{{.yes ?? {{incvar::bad}}}}|'
          '{{.zero ?? {{incvar::bad}}}}|{{.nil ?? fallback}}|'
          '{{.zero || default}}|{{.missing ?? default}}',
          c,
        ),
        'Y|Y|0|0|default|default',
      );
      expect(local.containsKey('bad'), isFalse);
      expect(
        engine.expand(
          '{{.new ??= {{incvar::counter}}}}|'
          '{{.new ??= {{incvar::counter}}}}|'
          '{{.zero ||= 003}}|{{.zero}}',
          c,
        ),
        '1|1|003|3',
      );
      expect(local['counter'], 1);
      expect(local['new'], '1');
      expect(local['zero'], '003');
    });

    test('string equality and numeric ordering use ST coercion', () {
      final c = context(local: {'n': '003', 'text': 'cat'});
      expect(
        engine.expand(
          '{{.n == 003}}|{{.n == 3}}|{{.n != 003}}|'
          '{{.n > 2}}|{{.n >= 3}}|{{.n < 4}}|{{.n <= 3}}|'
          '{{.text > 0}}|{{.missing >= 0}}',
          c,
        ),
        'false|true|true|true|true|true|true|false|true',
      );
    });

    test('variable aliases, delete, and global indexed writes', () {
      final local = <String, Object?>{'empty': ''};
      final global = <String, Object?>{};
      final c = context(local: local, global: global);
      expect(
        engine.expand(
          '{{varexists::empty}}|{{hasvar::missing}}|'
          '{{flushvar::empty}}{{hasvar::empty}}|'
          '{{setglobalvarindex::obj::name::hello}}'
          '{{getglobalvarindex::obj::name}}|{{globalvarexists::obj}}|'
          '{{flushglobalvar::obj}}{{hasglobalvar::obj}}',
          c,
        ),
        'true|false|false|hello|true|false',
      );
      expect(local, isEmpty);
      expect(global, isEmpty);
    });

    test('keyed value expands first, strings retain JSON-like content', () {
      final local = <String, Object?>{};
      final c = context(local: local);
      expect(
        engine.expand(
          '{{setvarkey::a::2::{{user}}}}'
          '{{getvar::a}}|{{getvarkey::a::2}}|{{getvarkey::a::0}}',
          c,
        ),
        '[null,null,"U"]|U|null',
      );
      expect(engine.expand('{{setvarkey::a::1.5::ignored}}{{getvar::a}}', c), '[null,null,"U"]');
    });
  });

  group('character environment and history', () {
    test('common fields, aliases, greeting index, and examples', () {
      final c = MacroContext(
        userName: 'U',
        card: {
          'name': 'Name',
          'nickname': 'Nick',
          'description': ' D {{user}} ',
          'personality': ' P ',
          'scenario': ' S ',
          'system_prompt': 'SYS',
          'post_history_instructions': 'POST',
          'creator_notes': ' Notes ',
          'character_version': ' 1 ',
          'first_mes': ' Hi {{char}} ',
          'alternate_greetings': [' One ', ' Two '],
          'mes_example': 'U: hello<START>\n{{char}}: bye',
          'extensions': {
            'depth_prompt': {'prompt': ' Depth '},
          },
        },
        persona: ' Persona ',
        model: 'm',
        isMobile: true,
        random: () => 0,
      );
      expect(
        engine.expand(
          '{{char}}|{{group}}|{{groupNotMuted}}|{{notChar}}|'
          '{{description}}|{{personality}}|{{scenario}}|{{persona}}|'
          '{{charPrompt}}|{{charInstruction}}|{{creatorNotes}}|'
          '{{charDepthPrompt}}|{{version}}|{{char_version}}|'
          '{{greeting}}|{{greeting::1}}|{{charFirstMessage::2}}|'
          '{{greeting::-1}}|{{greeting::9}}|{{model}}|{{isMobile}}',
          c,
        ),
        'Nick|Nick|Nick|U|D U|P|S|Persona|SYS|POST|Notes|Depth| 1 | 1 |'
        'Hi Nick|One|Two|||m|true',
      );
      expect(engine.expand('{{mesExamples}}', c), '<START>\nU: hello\n<START>\nNick: bye\n');
      expect(engine.expand('{{mesExamplesRaw}}', c), 'U: hello<START>\nNick: bye');
      expect(engine.expand('{{greeting::1.5}}', c), '{{greeting::1.5}}');
    });

    test('baseChatReplace disables every card field and retains original', () {
      final c = MacroContext(
        userName: 'U',
        charName: 'C',
        replaceCharacterCard: false,
        persona: 'P',
        card: {'description': 'D', 'first_mes': 'Hi', 'character_version': 'v'},
        random: () => 0,
      );
      expect(
        engine.expand(
          '{{user}}/{{char}}/{{description}}/{{persona}}/'
          '{{greeting}}/{{version}}/{{original}}',
          c,
        ),
        'U/C/////{{original}}',
      );
    });

    test('original absent survives first pass, one-shot consumption is per expand', () {
      final c = context();
      expect(engine.expand('a{{original}}b{{ORIGINAL}}', c), 'a{{original}}b{{ORIGINAL}}');
      final prepared = engine.expand(
        'SYS {{original}} {{user}}',
        MacroContext(userName: 'U', replaceCharacterCard: false, random: () => 0),
      );
      expect(prepared, 'SYS {{original}} U');
      expect(engine.expand('$prepared {{original}}', c, overrides: {'original': 'MAIN'}), 'SYS MAIN U ');
      expect(engine.expand('{{original}}{{original}}', c, overrides: {'ORIGINAL': 'NEXT'}), 'NEXT');
    });

    test('internal card expansion cannot inherit an outer original', () {
      final c = MacroContext(card: {'system_prompt': '{{original}}'}, original: 'MAIN');
      expect(engine.expand('{{charPrompt}}|{{original}}|{{original}}', c), '{{original}}|MAIN|');
      expect(
        engine.expand('{{charPrompt}}|{{original}}', c, overrides: {'original': 'OVERRIDE'}),
        '{{original}}|OVERRIDE',
      );
      // An explicitly requested base-mode call can still supply its own value.
      expect(
        engine.expand('{{original}}|{{original}}', MacroContext(replaceCharacterCard: false, original: 'BASE')),
        'BASE|',
      );
    });

    test('card fields are lazy, cache aliases in one expansion, reset between calls', () {
      final local = <String, Object?>{'x': 0};
      final c = context(local: local, card: {'personality': '{{incvar::x}}', 'description': '{{incvar::unused}}'});
      expect(engine.expand('plain', c), 'plain');
      expect(local, {'x': 0});
      expect(engine.expand('{{personality}}|{{charPersonality}}', c), '1|1');
      expect(engine.expand('{{personality}}', c), '2');
      expect(local.containsKey('unused'), isFalse);
      expect(engine.expand('{{if false}}{{description}}{{/if}}', c), '');
      expect(local.containsKey('unused'), isFalse);
    });

    test('eager initial pass then new lazy environments reproduce 1,2,2,3', () {
      final local = <String, Object?>{'x': 0};
      const raw = '{{incvar::x}}';
      final base = MacroContext(localVariables: local, replaceCharacterCard: false);
      expect(engine.expand(raw, base), '1');
      final c = context(local: local, card: {'personality': raw});
      expect(engine.expand('{{personality}}|{{personality}}', c), '2|2');
      expect(engine.expand('{{personality}}', c), '3');
    });

    test('alternate greeting list evaluates once as a whole, field recursion stops', () {
      final local = <String, Object?>{};
      final c = context(
        local: local,
        card: {
          'alternate_greetings': ['{{incvar::x}}', '{{incvar::x}}'],
          'description': 'A{{description}}{{personality}}B',
          'personality': 'P',
        },
      );
      expect(engine.expand('{{greeting::1}}|{{greeting::2}}|{{greeting::1}}', c), '1|2|1');
      expect(local['x'], 2);
      expect(engine.expand('{{description}}', c), 'AB');
      expect(engine.expand('{{greeting::1}}', c), '3');
      expect(local['x'], 4);
    });

    test('card cleanup order, preferences, and explicit chat overrides', () {
      final c = MacroContext(
        card: {
          'description': ' \rA\r\n\nB ',
          'character_version': ' {{user}} ',
          'system_prompt': 'card sys',
          'post_history_instructions': 'post',
          'scenario': 'card scene',
          'mes_example': 'card example',
        },
        userName: 'U',
        preferCharacterPrompt: false,
        preferCharacterJailbreak: false,
        scenarioOverride: ' chat scene ',
        mesExamplesOverride: ' chat example ',
        collapseNewlines: true,
        random: () => 0,
      );
      expect(
        engine.expand(
          '{{description}}|{{version}}|{{charPrompt}}|'
          '{{charInstruction}}|{{scenario}}|{{mesExamplesRaw}}',
          c,
        ),
        'A\nB| {{user}} |||chat scene|chat example',
      );
    });

    test('history skips swipe in progress and system only for role-specific lookups', () {
      final c = MacroContext(
        history: const [
          MacroMessage(text: 'user', isUser: true),
          MacroMessage(text: 'bot'),
          MacroMessage(text: 'sys', isSystem: true),
          MacroMessage(text: 'generating', swipeId: 2, swipeCount: 2),
        ],
        firstIncludedMessageId: 1,
        firstDisplayedMessageId: 0,
      );
      expect(
        engine.expand(
          '{{lastMessage}}|{{lastMessageId}}|'
          '{{lastUserMessage}}|{{lastCharMessage}}|{{lastSwipeId}}|'
          '{{currentSwipeId}}|{{firstIncludedMessageId}}|{{firstDisplayedMessageId}}',
          c,
        ),
        'sys|2|user|bot|2|3|1|0',
      );
      expect(engine.expand('{{lastMessageId}}{{lastSwipeId}}{{currentSwipeId}}', context()), '');
    });

    test('input, budgets, outlets, state and extension membership', () {
      final c = MacroContext(
        input: 'draft',
        maxContext: 900,
        maxResponse: 100,
        lastGenerationType: 'swipe',
        extensions: {'enabled'},
        outlets: {'knowledge': 'WORLD'},
        group: 'A, B',
        groupNotMuted: 'A',
        notChar: 'U, B',
      );
      expect(
        engine.expand(
          '{{input}}|{{maxPromptTokens}}|{{maxContext}}|'
          '{{maxResponse}}|{{outlet::knowledge}}|{{outlet::missing}}|'
          '{{lastGenerationType}}|{{hasExtension::enabled}}|'
          '{{hasExtension::disabled}}|{{group}}|{{groupNotMuted}}|{{notChar}}|'
          '{{banned::"word"}}',
          c,
        ),
        'draft|800|900|100|WORLD||swipe|true|false|A, B|A|U, B|',
      );
    });
  });

  group('random and time', () {
    test('random legacy separators and escaping, options eagerly evaluate', () {
      final local = <String, Object?>{};
      final c = context(local: local, random: () => 0.99);
      expect(
        engine.expand(
          '{{random::a::b}}|{{random:a::b}}|'
          r'{{random a\,b,c}}|{{random}}',
          c,
        ),
        'b|b|c|',
      );
      expect(engine.expand('{{random::{{incvar::x}}::{{incvar::x}}}}', c), '2');
      expect(local['x'], 2);
      expect(engine.expand(r'{{random a\,b,c}}', context(random: () => 0)), 'a,b');
    });

    test('dice uses one random draw per die; invalid notation consumes none', () {
      final sequence = [0.0, 0.5, 0.999];
      var position = 0;
      final c = context(random: () => sequence[position++]);
      expect(engine.expand('{{roll::3d6+4}}', c), '15');
      expect(position, 3);
      expect(engine.expand('{{roll::0d6}}|{{roll::bad}}|{{roll::1d0}}', c), '||');
      expect(position, 3);
      expect(engine.expand('{{roll 6}}', context(random: () => 0.5)), '4');
    });

    test('time timezone input, UTC legacy syntax, and exact Moment offset rule', () {
      final c = MacroContext(
        now: DateTime.utc(2024, 2, 29, 18, 7),
        timeZoneOffset: const Duration(hours: 8),
        locale: 'en',
      );
      expect(
        engine.expand(
          '{{time}}|{{date}}|{{weekday}}|{{isotime}}|{{isodate}}|'
          '{{time_UTC-5}}|{{time::UTC+16}}',
          c,
        ),
        '2:07 AM|March 1, 2024|Friday|02:07|2024-03-01|1:07 PM|6:23 PM',
      );
    });

    test('datetimeformat separates alias expansion from literal token boundaries', () {
      String formatted(String pattern, {String locale = 'en'}) => engine.expand(
        '{{datetimeformat::$pattern}}',
        MacroContext(now: DateTime.utc(2024, 2, 29, 18, 7, 8, 123), timeZoneOffset: Duration.zero, locale: locale),
      );
      // Moment 2.30.1 expands aliases before the basic formatting-token pass.
      for (final row in const [('en', 'LT1|6:07:08 PM'), ('zh-cn', 'LT1|18:07:08')]) {
        expect(
          formatted(r'\LTS|LTS', locale: row.$1),
          row.$2,
          reason: '${row.$1}: escaped LTS leaves S executable, while the ordinary alias expands',
        );
      }
      expect(formatted('LY'), '02/29/02024', reason: 'expanded L joins the adjacent Y into YYYYY');
      expect(formatted(r'[\MM]'), r'\MM', reason: 'bracket literals retain their internal backslash');
      expect(formatted('[x]MM]'), 'x]MM', reason: 'Moment bracket matching is greedy through closing brackets');
      expect(formatted(r'\\MM'), '02', reason: 'both literal backslashes disappear before the ordinary MM');
      expect(formatted('MM\\'), '02', reason: 'a trailing literal backslash also disappears');
      expect(
        formatted(r'\gggggg|\GGGGGG'),
        'gggggg|GGGGGG',
        reason: 'escaped five-letter tokens consume whole tokens without enabling new numeric outputs',
      );
      expect(formatted('HH\nmm'), '1807', reason: 'the token regex skips a newline outside brackets');
    });

    test('datetimeformat era families share the explicit context calendar boundary', () {
      String formatted(String pattern, DateTime instant, {String locale = 'en', Duration offset = Duration.zero}) =>
          engine.expand(
            '{{datetimeformat::$pattern}}',
            MacroContext(now: instant, timeZoneOffset: offset, locale: locale, random: () => 0.5),
          );
      const all = 'N|NN|NNN|NNNN|NNNNN|y|yy|yyy|yyyy|yo|YYYY';
      // Moment 2.30.1 era.js/en.js define the names and widths; zh-cn has no
      // era override and its ordinal for unit y is the number without a suffix.
      final rows = [
        (
          DateTime.utc(2024, 2, 29),
          'AD|AD|AD|Anno Domini|AD|2024|2024|2024|2024|2024th|2024',
          'AD|AD|AD|Anno Domini|AD|2024|2024|2024|2024|2024|2024',
        ),
        (
          DateTime.utc(1),
          'AD|AD|AD|Anno Domini|AD|1|01|001|0001|1st|0001',
          'AD|AD|AD|Anno Domini|AD|1|01|001|0001|1|0001',
        ),
        (
          DateTime.utc(0),
          'BC|BC|BC|Before Christ|BC|1|01|001|0001|1st|0000',
          'BC|BC|BC|Before Christ|BC|1|01|001|0001|1|0000',
        ),
        (
          DateTime.utc(-1),
          'BC|BC|BC|Before Christ|BC|2|02|002|0002|2nd|-0001',
          'BC|BC|BC|Before Christ|BC|2|02|002|0002|2|-0001',
        ),
      ];
      for (final row in rows) {
        expect(formatted(all, row.$1), row.$2, reason: 'en UTC calendar year ${row.$1.year}');
        expect(
          formatted(all, row.$1, locale: 'zh-cn'),
          row.$3,
          reason: 'zh-cn UTC calendar year ${row.$1.year} retains English era names',
        );
      }
      for (final locale in ['en', 'zh-cn']) {
        expect(
          formatted(r'[N NN NNN NNNN NNNNN y yy yyy yyyy yo]|\NNNN|\yyyy|\yo', rows.first.$1, locale: locale),
          'N NN NNN NNNN NNNNN y yy yyy yyyy yo|NNNN|yyyy|yo',
          reason: '$locale: bracket and full-token escapes stay literal after adding era outputs',
        );
        expect(
          formatted('NNNNNN|yyyyy', rows.first.$1, locale: locale),
          'ADAD|20242024',
          reason: '$locale: ordinary tokens use longest boundaries, not repeated single letters',
        );
      }
      // These are the approved same-Context policy, not Moment observations
      // with separately cached host-local era anchors and an instance offset.
      expect(
        formatted('N|y|YYYY-MM-DD HH:mm|Z', DateTime.utc(0, 12, 31, 16, 30), offset: const Duration(hours: 8)),
        'AD|1|0001-01-01 00:30|+08:00',
        reason: 'positive offset uses the same local year for era and calendar fields',
      );
      expect(
        formatted('N|y|YYYY-MM-DD HH:mm|Z', DateTime.utc(1, 1, 1, 0, 30), offset: const Duration(hours: -1)),
        'BC|1|0000-12-31 23:30|-01:00',
        reason: 'negative offset keeps year zero in BC with era year one',
      );
    });

    test('idle duration skips newest non-system message then finds older user', () {
      final now = DateTime.utc(2024, 1, 1, 12);
      final c = MacroContext(
        now: now,
        timeZoneOffset: Duration.zero,
        history: [
          MacroMessage(text: 'u0', isUser: true, sentAt: now.subtract(const Duration(hours: 1))),
          MacroMessage(text: 'u1', isUser: true, sentAt: now.subtract(const Duration(minutes: 2))),
          const MacroMessage(text: 'sys', isSystem: true),
          const MacroMessage(text: 'bot'),
        ],
      );
      expect(engine.expand('{{idleDuration}}', c), '2 minutes');
      expect(
        engine.expand(
          '{{idle_duration}}',
          MacroContext(
            now: now,
            history: [MacroMessage(text: 'only user', isUser: true, sentAt: now)],
          ),
        ),
        'just now',
      );
    });

    test('timeDiff direction, invalid dates and unsupported locale are explicit', () {
      expect(expand('{{timeDiff::2024-01-01 15:00:00::2024-01-01 12:00:00}}'), 'in 3 hours');
      expect(expand('{{timeDiff::2024-02-30::2024-02-29}}'), 'Invalid date');
      expect(expand('{{timeDiff::2024-01-01T24:00:00Z::2024-01-02T00:00:00Z}}'), 'a few seconds ago');
      expect(engine.expand('{{date}}', MacroContext(locale: 'unsupported')), '{{date}}');
    });
  });

  group('independent fixed-source oracle', () {
    final fixture = jsonDecode(File('test/fixtures/macro-oracle.json').readAsStringSync()) as Map<String, Object?>;
    List<Map<String, Object?>> rows(String key) => (fixture[key]! as List<Object?>).cast<Map<String, Object?>>();

    test('UTF-16 cyrb53 hashes including signed seeds', () {
      for (final row in rows('hashes')) {
        expect(
          MacroEngine.stringHash(row['text']! as String, row['seed']! as int),
          row['expected'],
          reason: jsonEncode(row),
        );
      }
    });

    test('actual ST pick handler + actual seedrandom, source offsets', () {
      for (final row in rows('picks')) {
        final c = MacroContext(
          userName: 'U',
          chatId: row['chatId']! as String,
          pickRerollSeed: row['reroll'],
          localVariables: Map<String, Object?>.from(row['local']! as Map<String, Object?>),
          card: row['card']! as Map<String, Object?>,
          random: () => throw StateError('pick must not consume injected random'),
        );
        expect(engine.expand(row['text']! as String, c), row['expected'], reason: row['id']! as String);
      }
    });

    test('actual ST variable functions, including key/array edge cases', () {
      for (final row in rows('variables')) {
        final local = Map<String, Object?>.from(row['local']! as Map<String, Object?>);
        final global = Map<String, Object?>.from(row['global']! as Map<String, Object?>);
        expect(
          engine.expand(row['text']! as String, context(local: local, global: global)),
          row['expected'],
          reason: row['id']! as String,
        );
        expect(local, row['afterLocal'], reason: row['id']! as String);
        expect(global, row['afterGlobal'], reason: row['id']! as String);
      }
    });

    test('Moment 2.30.1 localized and calendar format vectors', () {
      for (final row in rows('timeFormats')) {
        final c = MacroContext(
          now: DateTime.parse(row['now']! as String),
          locale: row['locale']! as String,
          timeZoneOffset: Duration(minutes: row['offset']! as int),
        );
        expect(engine.expand('{{datetimeformat::${row['format']}}}', c), row['expected'], reason: jsonEncode(row));
      }
    });

    test('Moment humanize boundaries and past/future suffixes', () {
      for (final row in rows('timeDiffs')) {
        final c = MacroContext(locale: row['locale']! as String, timeZoneOffset: Duration.zero);
        expect(
          engine.expand('{{timeDiff::${row['left']}::${row['right']}}}', c),
          row['expected'],
          reason: jsonEncode(row),
        );
      }
    });
  });
}
