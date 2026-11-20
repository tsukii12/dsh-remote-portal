import 'dart:io';

import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late Database database;
  late ChatStore store;
  late String chat;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t18-secret-commit-store-');
    path = '${directory.path}/tavern.sqlite3';
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    chat = store.createChat(id: 'chat', characterId: 'card', title: 'before');
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('a deferred foreign key makes COMMIT fail after the operation returns without adopting or notifying', () async {
    var operationReturned = false;
    var hookCalls = 0;
    final prepared = Object();
    Object? adopted;
    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    expect(
      () => store.transaction<int>(
        () {
          store.updateChat(chat, title: 'uncommitted candidate', metadata: {'candidate': 'B'});
          // The real chats FK is DEFERRABLE INITIALLY DEFERRED: this SQL succeeds,
          // so only the outer COMMIT can detect the unresolved node identity.
          database.execute('UPDATE chats SET current_leaf_id = ? WHERE id = ?', ['not-a-node', chat]);
          operationReturned = true;
          return 42;
        },
        onCommitted: () {
          hookCalls++;
          adopted = prepared;
        },
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(operationReturned, isTrue);
    expect(hookCalls, 0);
    expect(adopted, isNull);
    expect(database.autocommit, isTrue);
    expect(store.chat(chat).title, 'before');
    expect(store.chat(chat).metadata, isEmpty);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(changes, isEmpty);

    store.transaction<void>(
      () => store.updateChat(chat, title: 'later commit'),
      onCommitted: () {
        hookCalls++;
        adopted = prepared;
      },
    );
    expect(hookCalls, 1);
    expect(identical(adopted, prepared), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(changes, [chat]);
    await subscription.cancel();
  });

  test('one outer commit adopts once before chat and preset notifications and preserves its return value', () async {
    final before = Object(), prepared = Object();
    Object adopted = before;
    var hookCalls = 0;
    final order = <String>[];
    final observations = <({String kind, bool adopted, int calls})>[];
    final chats = store.changes.listen((id) {
      order.add('chat:$id');
      observations.add((kind: 'chat', adopted: identical(adopted, prepared), calls: hookCalls));
    });
    final presets = store.presetChanges.listen((_) {
      order.add('preset');
      observations.add((kind: 'preset', adopted: identical(adopted, prepared), calls: hookCalls));
    });
    store.beginStreamingWrites();
    expect(_synchronous(database), 1);
    final result = store.transaction<int>(
      () {
        expect(_synchronous(database), 2);
        store.updateChat(chat, title: 'committed candidate');
        store.updateChat(chat, metadata: {'candidate': 'B'});
        store.createPreset(name: 'saved', sourceText: '{}', raw: {});
        expect(identical(adopted, before), isTrue);
        order.add('operation');
        return 42;
      },
      onCommitted: () {
        adopted = prepared;
        hookCalls++;
        order.add('committed');
      },
    );
    expect(result, 42);
    expect(identical(adopted, prepared), isTrue);
    expect(hookCalls, 1);
    expect(order, ['operation', 'committed']);
    expect(database.autocommit, isTrue);
    expect(_synchronous(database), 1);
    expect(store.chat(chat).metadata, {'candidate': 'B'});
    await Future<void>.delayed(Duration.zero);
    expect(order.take(2), ['operation', 'committed']);
    expect(order.skip(2), unorderedEquals(['chat:$chat', 'preset']));
    expect(
      observations,
      unorderedEquals([(kind: 'chat', adopted: true, calls: 1), (kind: 'preset', adopted: true, calls: 1)]),
    );
    expect(hookCalls, 1);
    store.endStreamingWrites();
    expect(_synchronous(database), 2);
    await chats.cancel();
    await presets.cancel();
  });

  test('a throwing synchronous adoption hook propagates its own error after a durable commit', () async {
    final prepared = Object();
    Object? adopted;
    final failure = StateError('adoption fixture');
    var hookCalls = 0;
    expect(
      () => store.transaction<void>(
        () {
          store.updateChat(chat, title: 'already committed', metadata: {'candidate': 'B'});
        },
        onCommitted: () {
          adopted = prepared;
          hookCalls++;
          throw failure;
        },
      ),
      throwsA(same(failure)),
    );
    expect(hookCalls, 1);
    expect(identical(adopted, prepared), isTrue);
    expect(database.autocommit, isTrue);
    expect(store.chat(chat).title, 'already committed');
    expect(store.chat(chat).metadata, {'candidate': 'B'});
    var laterHookCalls = 0;
    expect(
      store.transaction<int>(
        () => 7,
        onCommitted: () {
          laterHookCalls++;
        },
      ),
      7,
    );
    expect(laterHookCalls, 1);
    expect(hookCalls, 1);
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    expect(store.chat(chat).title, 'already committed');
    expect(store.chat(chat).metadata, {'candidate': 'B'});
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('an identifiable async hook is rejected before either operation or hook body begins', () async {
    var operationCalls = 0;
    var hookCalls = 0;
    Future<void> hook() async {
      hookCalls++;
      await Future<void>.value();
      hookCalls++;
    }

    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    expect(
      () => store.transaction<void>(() {
        operationCalls++;
        store.updateChat(chat, title: 'must not commit');
      }, onCommitted: hook),
      throwsArgumentError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(operationCalls, 0);
    expect(hookCalls, 0);
    expect(store.chat(chat).title, 'before');
    expect(database.autocommit, isTrue);
    expect(changes, isEmpty);
    await subscription.cancel();
  });

  test('nested synchronous and async hooks reject before their operations without aborting the outer batch', () async {
    var operationCalls = 0;
    var innerHookCalls = 0;
    var outerHookCalls = 0;
    void synchronousHook() {
      innerHookCalls++;
    }

    Future<void> asynchronousHook() async {
      innerHookCalls++;
    }

    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    store.transaction<void>(
      () {
        store.updateChat(chat, title: 'outer before');
        for (final hook in <void Function()>[synchronousHook, asynchronousHook]) {
          expect(
            () => store.transaction<void>(() {
              operationCalls++;
              store.updateChat(chat, title: 'must not run');
            }, onCommitted: hook),
            throwsStateError,
          );
        }
        expect(operationCalls, 0);
        expect(innerHookCalls, 0);
        store.updateChat(chat, title: 'outer committed');
      },
      onCommitted: () {
        outerHookCalls++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(operationCalls, 0);
    expect(innerHookCalls, 0);
    expect(outerHookCalls, 1);
    expect(store.chat(chat).title, 'outer committed');
    expect(database.autocommit, isTrue);
    expect(changes, [chat]);
    await subscription.cancel();
  });
}

int _synchronous(Database database) => database.select('PRAGMA synchronous').single['synchronous'] as int;
