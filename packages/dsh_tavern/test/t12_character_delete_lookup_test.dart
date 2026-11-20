import 'dart:async';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card;

void main() {
  test('a character lookup error cannot report deletion while leaving the card and erasing its chats', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final before = await h.snapshot();
    expect(before['aTexts'], ['A greeting', 'kept A 海🌊']);
    expect(before['aVariables'], {'marker': 'kept'});
    final cardBytes = await h.cardFile.readAsBytes();
    final denied = PathAccessException(
      h.cardDirectory.path,
      OSError('Injected character directory lookup denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _LookupFault(h.cardDirectory, probeError: denied);
    final attempt = await h.attempt(fault);

    // Reopen both products normally: a warm character cache cannot conceal
    // that the old delete kept the original directory but removed its chats.
    await h.reopen();
    expect(
      <String, Object?>{'deleteSucceeded': attempt.succeeded, 'reopened': await h.snapshot()},
      {'deleteSucceeded': false, 'reopened': before},
      reason: 'Delete error: ${attempt.error}; IO: ${fault.log.join(' -> ')}',
    );
    expect(attempt.error, same(denied));
    expect(await h.cardFile.readAsBytes(), orderedEquals(cardBytes));
    expect(fault.probes, 1);

    // A later successful public delete removes both A and its chats, leaving B.
    await h.engine.deleteCharacter(h.characterA);
    await h.reopen();
    expect(await h.engine.character(h.characterA), isNull);
    expect(await h.engine.watchChats(characterId: h.characterA).first, isEmpty);
    expect((await h.engine.watchCharacters().first).map((card) => card.id), [h.characterB]);
    expect((await h.engine.path(h.chatB)).map((message) => message.text), ['B greeting', 'kept B']);
  });

  test('a successful identity probe cannot complete a character deletion without moving the directory', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final before = await h.snapshot();
    // The target type is hidden, but the identity query remains native and
    // really finds A. Reject the unknown type before any chat deletion.
    final fault = _LookupFault(h.cardDirectory);
    final attempt = await h.attempt(fault);
    await h.reopen();
    expect(
      <String, Object?>{'deleteSucceeded': attempt.succeeded, 'reopened': await h.snapshot()},
      {'deleteSucceeded': false, 'reopened': before},
    );
    expect(attempt.error, isA<FileSystemException>());
    expect(fault.probes, 1);
  });

  test('normal and genuinely missing character deletions remain idempotent and isolate other cards', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    await h.engine.deleteCharacter(h.characterA);
    expect(await h.cardDirectory.exists(), isFalse);
    await h.engine.deleteCharacter(h.characterA);
    await h.reopen();
    await h.engine.deleteCharacter(h.characterA);
    expect(await h.engine.character(h.characterA), isNull);
    expect(await h.engine.watchChats(characterId: h.characterA).first, isEmpty);
    expect((await h.engine.watchCharacters().first).map((card) => card.id), [h.characterB]);
    expect((await h.engine.watchChats().first).map((chat) => chat.id), [h.chatB]);
    expect((await h.engine.path(h.chatB)).map((message) => message.text), ['B greeting', 'kept B']);
  });

  test('non-absence and newly visible character entries cannot authorize deleting their chats', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final before = await h.snapshot();
    final errors = <Object>[
      PathNotFoundException(h.cardDirectory.path, const OSError('Network path unavailable', 53)),
      FileSystemException(
        'Not an explicit missing-path subtype',
        h.cardDirectory.path,
        const OSError('Other error', 2),
      ),
      if (!Platform.isWindows)
        PathNotFoundException(h.cardDirectory.path, const OSError('Not the POSIX missing-path code', 3)),
    ];
    for (final error in errors) {
      final fault = _LookupFault(h.cardDirectory, probeError: error);
      final attempt = await h.attempt(fault);
      expect(
        <String, Object?>{'deleteSucceeded': attempt.succeeded, 'snapshot': await h.snapshot()},
        {'deleteSucceeded': false, 'snapshot': before},
      );
      expect(attempt.error, same(error));
    }
    // These are classification boundaries, not real symlink/socket fixtures.
    for (final type in [
      FileSystemEntityType.directory,
      FileSystemEntityType.file,
      FileSystemEntityType.link,
      FileSystemEntityType.unixDomainSock,
    ]) {
      final error = PathNotFoundException(h.cardDirectory.path, const OSError('The target is now visible', 2));
      final fault = _LookupFault(h.cardDirectory, probeError: error, laterType: type);
      final attempt = await h.attempt(fault);
      expect(
        <String, Object?>{'deleteSucceeded': attempt.succeeded, 'snapshot': await h.snapshot()},
        {'deleteSucceeded': false, 'snapshot': before},
      );
      expect(attempt.error, same(error));
    }
    // The same owner's deletion marker and library queue must be usable again.
    final appended = await h.engine.sendOnly(h.chatA, 'after the failed deletes');
    expect((await h.engine.path(h.chatA)).last.nodeId, appended.nodeId);
    await h.engine.deleteCharacter(h.characterA);
    await h.reopen();
    expect(await h.engine.character(h.characterA), isNull);
    expect((await h.engine.watchChats().first).map((chat) => chat.id), [h.chatB]);
  });
}

class _Fixture {
  _Fixture(this.root, this.engine, this.characterA, this.characterB, this.chatA, this.chatB);
  final Directory root;
  TavernEngine engine;
  final String characterA;
  final String characterB;
  final String chatA;
  final String chatB;
  Directory get cardDirectory => Directory('${root.path}/characters/$characterA');
  File get cardFile => File('${cardDirectory.path}/card.json');

  static Future<_Fixture> open() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-character-delete-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    TavernEngine? owner;
    try {
      owner = await TavernEngine.openDirectory(root);
      final a = await owner.importCard(t24Card(greeting: 'A greeting'));
      final b = await owner.importCard(t24Card(greeting: 'B greeting'));
      final chatA = await owner.createChat(a.id);
      final chatB = await owner.createChat(b.id);
      await owner.sendOnly(chatA, '{{setvar::marker::kept}}kept A 海🌊');
      await owner.sendOnly(chatB, 'kept B');
      return _Fixture(root, owner, a.id, b.id, chatA, chatB);
    } catch (_) {
      await owner?.close();
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<Map<String, Object?>> snapshot() async {
    final cards = (await engine.watchCharacters().first).map((card) => card.id).toList()..sort();
    final chats = (await engine.watchChats().first).map((chat) => chat.id).toList()..sort();
    final a = chats.contains(chatA) ? await engine.path(chatA) : <TavernMessage>[];
    final b = chats.contains(chatB) ? await engine.path(chatB) : <TavernMessage>[];
    return {
      'cardIds': cards,
      'chatIds': chats,
      'aNodeIds': a.map((message) => message.nodeId).toList(),
      'aTexts': a.map((message) => message.text).toList(),
      'aVariables': chats.contains(chatA) ? await engine.readVariables(chatA) : null,
      'bNodeIds': b.map((message) => message.nodeId).toList(),
      'bTexts': b.map((message) => message.text).toList(),
    };
  }

  Future<_DeleteAttempt> attempt(_LookupFault fault) async {
    var succeeded = false;
    Object? error;
    await fault.run(() async {
      try {
        await engine.deleteCharacter(characterA);
        succeeded = true;
      } catch (caught) {
        error = caught;
      }
    });
    return _DeleteAttempt(succeeded, error);
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(root);
  }

  Future<void> dispose() async {
    try {
      await engine.close();
    } finally {
      await root.delete(recursive: true);
    }
  }
}

class _DeleteAttempt {
  _DeleteAttempt(this.succeeded, this.error);
  final bool succeeded;
  final Object? error;
}

class _LookupFault {
  _LookupFault(this.directory, {this.probeError, this.laterType = FileSystemEntityType.notFound});
  final Directory directory;
  final Object? probeError;
  final FileSystemEntityType laterType;
  final log = <String>[];
  var lookups = 0;
  var probes = 0;

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final selected = File(directory.path).absolute.uri;
    bool matches(String path) => parent.run(() => File(path).absolute.uri == selected);
    await IOOverrides.runZoned(
      body,
      fseGetType: (path, followLinks) {
        if (matches(path)) {
          lookups++;
          final result = lookups == 1 ? FileSystemEntityType.notFound : laterType;
          log.add('type:$result,followLinks:$followLinks');
          return Future.value(result);
        }
        return parent.run(() => FileSystemEntity.type(path, followLinks: followLinks));
      },
      fseIdentical: (left, right) async {
        if (matches(left) && matches(right)) {
          probes++;
          log.add('identical');
          if (probeError case final error?) {
            throw error;
          }
        }
        return parent.run(() => FileSystemEntity.identical(left, right));
      },
    );
  }
}
