import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';

// Fixed ST 7e8663cd9c184a550b37238218bdd32c6efc68e9.
// Actual-source V8 probes cover both hash resolvers, legacy evaluator/card
// order, new pick handler and the exact pinned seedrandom dependency.
// Parser/lazy-path cases below exercise the Dart integration of those rules.
// Notifications observe hash lookups, including hits, not just metadata writes.
void main() {
  const modern = MacroEngine();
  const legacy = LegacyMacroEngine();
  const pick = '{{pick::a::b::c::d::e::f::g::h::i::j}}';
  const reviewHash = 3994932676295448;

  final cases = <(String, num?, num, String, String)>[
    ('missing', null, reviewHash, 'd', 'c'),
    ('zero', 0, 0, 'a', 'c'),
    ('nonzero', 42, 42, 'g', 'e'),
    ('fractional', 0.5, 0.5, 'c', 'i'),
  ];
  for (final (label, hash, modernHash, modernOutput, legacyOutput) in cases) {
    test('modern reports the actual $label cache only when a pick executes', () {
      final hashes = <num>[];
      final context = MacroContext(
        chatId: 'Review',
        chatIdHash: hash,
        replaceCharacterCard: false,
        onChatIdHash: hashes.add,
      );
      expect(hashes, isEmpty, reason: 'Construction does not look up the native cache.');
      for (final text in ['', 'plain', '{{pick}}', '{{if false}}{{pick::a::b}}{{/if}}']) {
        modern.expand(text, context);
        expect(hashes, isEmpty, reason: 'No evaluated nonempty pick in $text.');
      }
      expect(modern.expand(pick, context), modernOutput);
      expect(hashes, [modernHash]);
      expect(context.chatIdHash, hash ?? reviewHash);
    });

    test('legacy reports the actual $label cache for each nonempty evaluation', () {
      final hashes = <num>[];
      final context = MacroContext(
        chatId: 'Review',
        chatIdHash: hash,
        replaceCharacterCard: false,
        onChatIdHash: hashes.add,
      );
      final effective = hash == null || hash == 0 ? reviewHash : hash;
      expect(hashes, isEmpty);
      expect(legacy.expand('', context), '');
      expect(hashes, isEmpty);
      expect(legacy.expand('plain', context), 'plain');
      expect(hashes, [effective]);
      expect(legacy.expand(' ', context), ' ');
      expect(hashes, [effective, effective]);
      legacy.expand('$pick/$pick', context);
      expect(hashes, [
        effective,
        effective,
        effective,
      ], reason: 'The old factory is constructed once, not once per match.');
      expect(legacy.expand(pick, context), legacyOutput);
      expect(hashes, List<num>.filled(4, effective));
      expect(context.chatIdHash, hash ?? reviewHash);
    });
  }

  final bridges = <(String, num?, String, num, String)>[
    ('zero then legacy plain', 0, 'plain', reviewHash, 'd'),
    ('zero then legacy empty', 0, '', 0, 'a'),
    ('nonzero then legacy plain', 42, 'plain', 42, 'g'),
    ('missing then legacy plain', null, 'plain', reviewHash, 'd'),
    ('fractional then legacy plain', 0.5, 'plain', 0.5, 'c'),
    ('missing then legacy empty', null, '', reviewHash, 'd'),
  ];
  for (final (label, initial, text, expectedHash, expectedPick) in bridges) {
    test('external cache bridge: $label', () {
      num? cache = initial;
      final notifications = <num>[];
      MacroContext context() => MacroContext(
        chatId: 'Review',
        chatIdHash: cache,
        replaceCharacterCard: false,
        onChatIdHash: (value) {
          notifications.add(value);
          cache = value;
        },
      );
      expect(legacy.expand(text, context()), text);
      if (text.isEmpty) {
        expect(notifications, isEmpty);
        expect(cache, initial);
      }
      expect(modern.expand(pick, context()), expectedPick);
      expect(cache, expectedHash);
      expect(notifications, [if (text.isNotEmpty) expectedHash, expectedHash]);
    });
  }

  test('a shared context keeps its hash unchanged across both engines', () {
    final hashes = <num>[];
    final context = MacroContext(
      chatId: 'review',
      chatIdHash: 0,
      replaceCharacterCard: false,
      onChatIdHash: hashes.add,
    );
    expect(legacy.expand(pick, context), 'h');
    expect(context.chatIdHash, 0);
    expect(modern.expand(pick, context), 'a');
    expect(hashes, [7944625591574698, 0]);
    expect(context.chatId, 'review');
    expect(context.chatIdHash, 0);
  });

  test('modern distinguishes no items from one empty item and counts nested lookups', () {
    final hashes = <num>[];
    final context = MacroContext(chatIdHash: 42, replaceCharacterCard: false, onChatIdHash: hashes.add);
    expect(modern.expand('{{pick}}', context), '');
    expect(hashes, isEmpty);
    expect(modern.expand('{{pick::}}', context), '');
    expect(hashes, [42]);
    hashes.clear();
    modern.expand('{{pick::{{pick::a::b}}::c}}', context);
    expect(hashes, [42, 42]);
    hashes.clear();
    modern.expand('$pick/$pick', context);
    expect(hashes, [42, 42]);
  });

  test('modern only observes the chosen if and coalesce branches', () {
    final hashes = <num>[];
    final local = <String, Object?>{'x': 'present'};
    final context = MacroContext(
      chatIdHash: 42,
      localVariables: local,
      replaceCharacterCard: false,
      onChatIdHash: hashes.add,
    );
    expect(modern.expand('{{if false}}{{pick::a::b}}{{else}}safe{{/if}}', context), 'safe');
    expect(modern.expand('{{.x??{{pick::a::b}}}}', context), 'present');
    expect(hashes, isEmpty);
    modern.expand('{{if true}}{{pick::a::b}}{{/if}}', context);
    expect(hashes, [42]);
    local.remove('x');
    modern.expand('{{.x??{{pick::a::b}}}}', context);
    expect(hashes, [42, 42]);
  });

  test('modern reports after pick arguments and before result postprocessing', () {
    final local = <String, Object?>{'n': 0};
    final events = <List<Object?>>[];
    final context = MacroContext(
      chatIdHash: 42,
      localVariables: local,
      replaceCharacterCard: false,
      onChatIdHash: (_) => events.add(['hash', local['n']]),
    );
    modern.expand(
      '{{pick::{{incvar::n}}::B}}',
      context,
      postProcess: (value) {
        events.add(['post', value]);
        return value;
      },
    );
    expect(events.take(2), [
      ['post', '1'],
      ['hash', 1],
    ]);
    expect(events, hasLength(3));
    expect(events.last.first, 'post');
    expect(local['n'], 1);
  });

  test('legacy observes eager fields before their replacements, then the outer factory', () {
    final local = <String, Object?>{'n': 0};
    final observations = <num>[];
    final hashes = <num>[];
    const increment = '{{incvar::n}}';
    final context = MacroContext(
      chatId: 'Review',
      chatIdHash: 0,
      localVariables: local,
      persona: increment,
      card: const {
        'system_prompt': increment,
        'mes_example': increment,
        'description': increment,
        'personality': increment,
        'scenario': increment,
        'post_history_instructions': increment,
        'extensions': {
          'depth_prompt': {'prompt': increment},
        },
        'creator_notes': increment,
        'first_mes': increment,
        'alternate_greetings': [increment, '  ', increment],
      },
      onChatIdHash: (hash) {
        hashes.add(hash);
        observations.add(local['n']! as num);
      },
    );
    expect(legacy.expand('', context), '');
    expect(observations, isEmpty);
    expect(local['n'], 0);
    expect(legacy.expand('plain', context), 'plain');
    expect(observations, List<num>.generate(13, (index) => index));
    expect(hashes, List<num>.filled(13, reviewHash));
    expect(local['n'], 12);
    expect(context.chatIdHash, 0);
  });

  test('modern skips unused card fields and shares each lazy field lookup', () {
    final hashes = <num>[];
    final local = <String, Object?>{'n': 0};
    final context = MacroContext(
      chatIdHash: 42,
      localVariables: local,
      card: const {'description': '{{incvar::n}}{{pick::a::b}}'},
      onChatIdHash: hashes.add,
    );
    expect(modern.expand('plain', context), 'plain');
    expect(hashes, isEmpty);
    expect(local['n'], 0);
    final copies = modern.expand('{{description}}/{{description}}', context).split('/');
    expect(copies, hasLength(2));
    expect(copies.first, copies.last);
    expect(hashes, [42]);
    expect(local['n'], 1);
  });

  test('modern uses JS numeric spelling for an integral double cache', () {
    final whole = MacroContext(chatId: 'Review', chatIdHash: 42, replaceCharacterCard: false);
    final decimal = MacroContext(chatId: 'Review', chatIdHash: 42.0, replaceCharacterCard: false);
    expect(modern.expand(pick, whole), 'g');
    expect(modern.expand(pick, decimal), 'g');
  });

  test('legacy uses JS numeric spelling for an integral double cache', () {
    final whole = MacroContext(chatId: 'Review', chatIdHash: 42, replaceCharacterCard: false);
    final decimal = MacroContext(chatId: 'Review', chatIdHash: 42.0, replaceCharacterCard: false);
    expect(legacy.expand(pick, whole), 'e');
    expect(legacy.expand(pick, decimal), 'e');
  });
}
