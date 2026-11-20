import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Regression for the T11 greeting regex integration and createChat failures.
// The failure is the actual fixed-ST named-groups callback case, not a mock
// exception injected into the macro engine.
void main() {
  for (final legacy in [false, true]) {
    group(legacy ? 'legacy macros' : 'modern macros', () {
      late Directory directory;
      late TavernEngine engine;

      Future<TavernEngine> open() => TavernEngine.openDirectory(
        directory,
        config: TavernModelConfig(apiKey: () async => null),
        clock: () => DateTime.utc(2026, 11, 10),
        random: () => 0.25,
      );

      Future<void> reopen() async {
        await engine.close();
        engine = await open();
      }

      Future<String> prepare(List<Map<String, Object?>> scripts) async {
        await engine.setSettings({'macroEngine': legacy ? 'legacy' : 'modern', 'globalRegexScripts': scripts});
        final card = await engine.importCard(_card(), fileName: 'create-failure.json');
        return card.id;
      }

      Future<Object?> diskG() async {
        final text = await File('${directory.path}/settings.json').readAsString();
        final document = jsonDecode(text) as Map<String, Object?>;
        return (document['globalVariables']! as Map<String, Object?>)['g'];
      }

      Future<void> noChats() async {
        expect(await engine.watchChats().first, isEmpty);
      }

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('dsh-create-failure-');
        engine = await open();
        await engine.setGlobalVariables({'g': 0});
      });

      tearDown(() async {
        await engine.close();
        await directory.delete(recursive: true);
      });

      test('later real regex failure keeps globals, saves, and rolls back chat', () async {
        final characterId = await prepare([_increment(), _badCapture()]);
        final failure = await _captureFailure(engine.createChat(characterId));
        _expectOriginalRegexFailure(failure.error);
        expect(engine.globalVariables['g'], 1);
        await noChats();
        // This must pass before close; a later unrelated save is insufficient.
        expect(await diskG(), 1);

        await reopen();
        expect(engine.globalVariables['g'], 1);
        await noChats();
      });

      test('error before any global change does not attempt a blocked save', () async {
        final characterId = await prepare([_badCapture()]);
        final blocker = Directory('${directory.path}/settings.json.writing');
        await blocker.create();

        final failure = await _captureFailure(engine.createChat(characterId));
        _expectOriginalRegexFailure(failure.error);
        expect(failure.error.toString(), isNot(contains('Saving global variables also failed')));
        expect(engine.globalVariables['g'], 0);
        expect(await diskG(), 0);
        await noChats();

        await engine.close();
        await blocker.delete();
        engine = await open();
        expect(engine.globalVariables['g'], 0);
        await noChats();
      });

      test('save failure exposes both errors and does not pretend globals persisted', () async {
        final characterId = await prepare([_increment(), _badCapture()]);
        final blocker = Directory('${directory.path}/settings.json.writing');
        await blocker.create();

        final failure = await _captureFailure(engine.createChat(characterId));
        expect(failure.error, isA<Exception>());
        final description = failure.error.toString();
        expect(description, contains('createChat failed'));
        expect(description, contains('ST regex fail-after-global:'));
        expect(description, contains(r'$4 resolves to the named-groups object'));
        expect(description, contains('Saving global variables also failed'));
        expect(description, contains('settings.json.writing'));
        // The carrier type is private, but its error/stack getters are public.
        // Check the actual filesystem error, including platform subclasses
        // such as Windows PathAccessException, without matching its class name.
        final dynamic carrier = failure.error;
        _expectOriginalRegexFailure(carrier.createError as Object);
        final saveError = carrier.saveError as Object;
        expect(saveError, isA<FileSystemException>());
        expect((saveError as FileSystemException).path, endsWith('settings.json.writing'));
        for (final stack in [carrier.createStackTrace as StackTrace, carrier.saveStackTrace as StackTrace]) {
          expect(stack.toString().trim(), isNotEmpty);
        }
        expect(engine.globalVariables['g'], 1);
        expect(await diskG(), 0);
        await noChats();

        // close waits for queues but does not retry a failed settings write.
        await engine.close();
        expect(await diskG(), 0);
        await blocker.delete();
        engine = await open();
        expect(engine.globalVariables['g'], 0);
        await noChats();
      });

      if (!legacy) {
        test('successful greeting keeps one global effect and persists it', () async {
          final characterId = await prepare([_increment()]);
          final chatId = await engine.createChat(characterId);
          expect((await engine.path(chatId)).single.text, '1ax');
          expect(engine.globalVariables['g'], 1);
          expect(await diskG(), 1);
          expect((await engine.watchChats().first).single.id, chatId);

          await reopen();
          expect(engine.globalVariables['g'], 1);
          expect((await engine.path(chatId)).single.text, '1ax');
        });

        test('a save failure after SQL success keeps the existing single-error behavior', () async {
          final characterId = await prepare([_increment()]);
          final blocker = Directory('${directory.path}/settings.json.writing');
          await blocker.create();

          final failure = await _captureFailure(engine.createChat(characterId));
          expect(failure.error, isA<FileSystemException>());
          expect(failure.error.toString(), contains('settings.json.writing'));
          expect(failure.error.toString(), isNot(contains('createChat failed:')));
          expect(engine.globalVariables['g'], 1);
          final committed = (await engine.watchChats().first).single;
          expect((await engine.path(committed.id)).single.text, '1ax');
          expect(await diskG(), 0);

          await engine.close();
          await blocker.delete();
          engine = await open();
          expect(engine.globalVariables['g'], 0);
          expect((await engine.path(committed.id)).single.text, '1ax');
        });

        test('SQLite failure after the greeting effect also persists the globals', () async {
          final characterId = await prepare([_increment()]);
          await engine.close();
          final database = sqlite3.open('${directory.path}/tavern.sqlite3');
          try {
            database.execute(
              'CREATE TRIGGER reject_create_greeting BEFORE INSERT ON nodes '
              "BEGIN SELECT RAISE(ABORT, 'create-greeting-node-abort'); END",
            );
          } finally {
            database.close();
          }
          engine = await open();

          final failure = await _captureFailure(engine.createChat(characterId));
          expect(failure.error, isA<SqliteException>());
          expect(failure.error.toString(), contains('create-greeting-node-abort'));
          expect(engine.globalVariables['g'], 1);
          await noChats();
          expect(await diskG(), 1);

          await reopen();
          expect(engine.globalVariables['g'], 1);
          await noChats();
        });
      }
    });
  }
}

Future<({Object error, StackTrace stack})> _captureFailure(Future<String> action) async {
  try {
    await action;
  } catch (error, stack) {
    return (error: error, stack: stack);
  }
  throw TestFailure('Expected createChat to fail.');
}

void _expectOriginalRegexFailure(Object error) {
  expect(error, isA<StateError>());
  expect(error.toString(), contains('ST regex fail-after-global:'));
  expect(error.toString(), contains(r'$4 resolves to the named-groups object'));
}

Map<String, Object?> _increment() =>
    _script(name: 'global-before-failure', pattern: r'^ax$', replacement: '{{incglobalvar::g}}ax');

Map<String, Object?> _badCapture() => _script(name: 'fail-after-global', pattern: '(?<n>x)', replacement: r'$4');

Map<String, Object?> _script({required String name, required String pattern, required String replacement}) => {
  'id': name,
  'scriptName': name,
  'findRegex': pattern,
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Recovery',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'ax',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
      },
    }),
  ),
);
