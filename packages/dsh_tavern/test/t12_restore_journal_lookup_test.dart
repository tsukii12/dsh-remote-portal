import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card;

void main() {
  test('restore journal lookup errors cannot open an empty root over a prepared recovery', () async {
    final h = await _Fixture.preparedGap();
    addTearDown(h.dispose);
    final saved = await h.artifacts();
    final denied = PathAccessException(
      h.journal.path,
      OSError('Injected journal lookup denial', Platform.isWindows ? 5 : 13),
    );
    final fault = _LookupFault(h.journal, probeError: denied);
    final attempt = await h.attempt(fault);
    final createdDuringFault = await h.root.exists();
    await h.closeOwner();
    final afterFault = await h.artifacts();

    // Both products now make the same normal public open attempt. The old
    // empty root obstructs rollback; the fixed product can restore previous.
    final retry = await h.attempt();
    final recovered = await h.visibleSnapshot();
    expect(
      <String, Object?>{
        'faultOpenReturned': attempt.engine != null,
        'createdRootDuringFault': createdDuringFault,
        'retryReturned': retry.engine != null,
        'recovered': recovered,
      },
      {
        'faultOpenReturned': false,
        'createdRootDuringFault': false,
        'retryReturned': true,
        'recovered': h.expectedSnapshot,
      },
      reason: 'Fault: ${attempt.error}; retry: ${retry.error}; IO: ${fault.log.join(' -> ')}',
    );
    expect(attempt.error, same(denied));
    expect(retry.error, isNull);
    expect(afterFault, saved);
    expect(await h.journal.exists(), isFalse);
    expect(await h.work.exists(), isFalse);
    expect(fault.probes, 1);
    await h.closeOwner();
    await h.attempt();
    expect(await h.visibleSnapshot(), h.expectedSnapshot);
  });

  test('a successful journal identity probe does not authorize opening an unknown root', () async {
    final h = await _Fixture.preparedGap();
    addTearDown(h.dispose);
    final saved = await h.artifacts();
    // Only the initial type lookup lies. The identity operation is native and
    // really finds the regular, readable journal; it must still fail closed.
    final fault = _LookupFault(h.journal);
    final attempt = await h.attempt(fault);
    final createdDuringFault = await h.root.exists();
    await h.closeOwner();
    final afterFault = await h.artifacts();
    final retry = await h.attempt();
    expect(
      <String, Object?>{
        'faultOpenReturned': attempt.engine != null,
        'createdRootDuringFault': createdDuringFault,
        'retryReturned': retry.engine != null,
        'recovered': await h.visibleSnapshot(),
      },
      {
        'faultOpenReturned': false,
        'createdRootDuringFault': false,
        'retryReturned': true,
        'recovered': h.expectedSnapshot,
      },
    );
    expect(attempt.error, isA<FileSystemException>());
    expect(retry.error, isNull);
    expect(afterFault, saved);
    expect(fault.probes, 1);
  });

  test('genuinely missing restore journals allow first open and later reopen', () async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-journal-missing-');
    final parent = Directory(await temporary.resolveSymbolicLinks());
    TavernEngine? owner;
    addTearDown(() async {
      await owner?.close();
      await parent.delete(recursive: true);
    });
    for (final nestedParent in [false, true]) {
      final root = Directory('${parent.path}/${nestedParent ? 'missing/child' : 'root'}');
      final journal = _journalFile(root);
      expect(await journal.exists(), isFalse);
      owner = await TavernEngine.openDirectory(root);
      expect(await owner.watchChats().first, isEmpty);
      await owner.setSettings({'freshRoot': nestedParent});
      await owner.close();
      owner = await TavernEngine.openDirectory(root);
      expect((await owner.readSettings())['freshRoot'], nestedParent);
      expect(await journal.exists(), isFalse);
      await owner.close();
      owner = null;
    }
  });

  test('journal probe errors and visible entries keep the prepared artifacts retryable', () async {
    final h = await _Fixture.preparedGap();
    addTearDown(h.dispose);
    final saved = await h.artifacts();
    final failures = <Object>[
      PathNotFoundException(h.journal.path, const OSError('Network path unavailable', 53)),
      FileSystemException('Not a missing-path subtype', h.journal.path, const OSError('Unclassified error', 2)),
      if (!Platform.isWindows)
        PathNotFoundException(h.journal.path, const OSError('Not the POSIX missing-path code', 3)),
    ];
    for (final error in failures) {
      final fault = _LookupFault(h.journal, probeError: error);
      final attempt = await h.attempt(fault);
      await h.closeOwner();
      expect(
        <String, Object?>{'faultOpenReturned': attempt.engine != null, 'rootExists': await h.root.exists()},
        {'faultOpenReturned': false, 'rootExists': false},
      );
      expect(attempt.error, same(error));
      expect(await h.artifacts(), saved);
    }

    // A missing-like probe cannot override a later no-follow classification.
    // These classifications are injected, not real symlink/socket fixtures.
    for (final type in [
      FileSystemEntityType.file,
      FileSystemEntityType.link,
      FileSystemEntityType.directory,
      FileSystemEntityType.unixDomainSock,
    ]) {
      final error = PathNotFoundException(h.journal.path, const OSError('Entry is now visible', 2));
      final fault = _LookupFault(h.journal, probeError: error, laterType: type);
      final attempt = await h.attempt(fault);
      await h.closeOwner();
      expect(
        <String, Object?>{'faultOpenReturned': attempt.engine != null, 'rootExists': await h.root.exists()},
        {'faultOpenReturned': false, 'rootExists': false},
      );
      expect(attempt.error, same(error));
      expect(await h.artifacts(), saved);
    }

    // Preserve the existing rejection of a real directory at the journal path.
    final held = await h.journal.rename('${h.journal.path}.held');
    final obstacle = Directory(h.journal.path);
    await obstacle.create();
    late final _OpenAttempt directoryAttempt;
    try {
      directoryAttempt = await h.attempt();
    } finally {
      await h.closeOwner();
      await obstacle.delete();
      await held.rename(h.journal.path);
    }
    expect(directoryAttempt.engine, isNull);
    expect(directoryAttempt.error, isA<FileSystemException>());
    expect(await h.root.exists(), isFalse);
    expect(await h.artifacts(), saved);
    final retry = await h.attempt();
    expect(retry.error, isNull);
    expect(await h.visibleSnapshot(), h.expectedSnapshot);
  });
}

class _Fixture {
  _Fixture(this.parent, this.root, this.work, this.journal, this.chatId, this.characterId, this.nodeId);
  final Directory parent;
  final Directory root;
  final Directory work;
  final File journal;
  final String chatId;
  final String characterId;
  final String nodeId;
  TavernEngine? engine;

  // Both databases come from real public operations. The incoming tree is
  // produced by backup + restore, then normally edited and closed. Only the
  // prepared journal and the between-renames placement are constructed; this
  // is not an actual killed process or a claim about power-loss durability.
  static Future<_Fixture> preparedGap() async {
    final temporary = await Directory.systemTemp.createTemp('dsh-t12-journal-gap-');
    final parent = Directory(await temporary.resolveSymbolicLinks());
    final root = Directory('${parent.path}/root');
    final candidate = Directory('${parent.path}/candidate');
    final archive = File('${parent.path}/incoming.zip');
    TavernEngine? owner;
    try {
      owner = await TavernEngine.openDirectory(root);
      await owner.setSettings({'recoveryMarker': 'original A 🌊'});
      await owner.setGlobalVariables({'G': 'original globals'});
      final card = await owner.importCard(t24Card(greeting: 'original greeting'));
      final chatId = await owner.createChat(card.id);
      final message = await owner.sendOnly(chatId, 'committed A');
      await owner.backup(archive.path);
      await owner.close();
      owner = null;
      await restoreTavernDirectory(archive.path, candidate.path);
      owner = await TavernEngine.openDirectory(candidate);
      await owner.setSettings({'recoveryMarker': 'incoming B'});
      await owner.setGlobalVariables({'G': 'incoming globals'});
      await owner.sendOnly(chatId, 'unpublished B');
      await owner.close();
      owner = null;

      final key = _rootKey(root);
      final id = sha256.convert(utf8.encode(key)).toString().substring(0, 16);
      final work = await parent.createTemp('.dshgo-restore-$id-');
      await candidate.rename('${work.path}/incoming');
      final journal = _journalFile(root);
      await journal.writeAsString(
        jsonEncode({
          'format': 'dshgo-tavern-restore',
          'version': 1,
          'root': key,
          'workName': work.uri.pathSegments.where((part) => part.isNotEmpty).last,
          'hadRoot': true,
          'phase': 'prepared',
        }),
        flush: true,
      );
      await root.rename('${work.path}/previous');
      return _Fixture(parent, root, work, journal, chatId, card.id, message.nodeId);
    } catch (_) {
      await owner?.close();
      await parent.delete(recursive: true);
      rethrow;
    }
  }

  Map<String, Object?> get expectedSnapshot => {
    'chatIds': [chatId],
    'marker': 'original A 🌊',
    'globals': {'G': 'original globals'},
    'characterId': characterId,
    'nodeIds': [nodeId],
    'texts': ['original greeting', 'committed A'],
  };

  Future<Map<String, Object?>?> visibleSnapshot() async {
    final owner = engine;
    if (owner == null) {
      return null;
    }
    final chats = await owner.watchChats().first;
    final path = chats.any((chat) => chat.id == chatId) ? await owner.path(chatId) : <TavernMessage>[];
    return {
      'chatIds': chats.map((chat) => chat.id).toList(),
      'marker': (await owner.readSettings())['recoveryMarker'],
      'globals': owner.globalVariables,
      'characterId': (await owner.character(characterId))?.id,
      'nodeIds': path.where((message) => message.role == TavernRole.user).map((message) => message.nodeId).toList(),
      'texts': path.map((message) => message.text).toList(),
    };
  }

  Future<Map<String, Uint8List>> artifacts() async => {
    'journal': await journal.readAsBytes(),
    'previousDatabase': await File('${work.path}/previous/tavern.sqlite3').readAsBytes(),
    'previousSettings': await File('${work.path}/previous/settings.json').readAsBytes(),
    'incomingDatabase': await File('${work.path}/incoming/tavern.sqlite3').readAsBytes(),
    'incomingSettings': await File('${work.path}/incoming/settings.json').readAsBytes(),
  };

  Future<_OpenAttempt> attempt([_LookupFault? fault]) async {
    TavernEngine? opened;
    Object? error;
    Future<void> open() async {
      try {
        opened = await TavernEngine.openDirectory(root);
      } catch (caught) {
        error = caught;
      }
    }

    if (fault == null) {
      await open();
    } else {
      await fault.run(open);
    }
    // Acquire every returned owner before an assertion or cleanup can fail.
    engine = opened;
    return _OpenAttempt(opened, error);
  }

  Future<void> closeOwner() async {
    final owner = engine;
    engine = null;
    await owner?.close();
  }

  Future<void> dispose() async {
    try {
      await closeOwner();
    } finally {
      await parent.delete(recursive: true);
    }
  }
}

String _rootKey(Directory root) {
  final key = root.absolute.uri.toString();
  return Platform.isWindows || Platform.isMacOS ? key.toLowerCase() : key;
}

File _journalFile(Directory root) {
  final id = sha256.convert(utf8.encode(_rootKey(root))).toString().substring(0, 16);
  return File('${root.parent.path}/.dshgo-restore-$id.json');
}

class _OpenAttempt {
  _OpenAttempt(this.engine, this.error);
  final TavernEngine? engine;
  final Object? error;
}

class _LookupFault {
  _LookupFault(this.journal, {this.probeError, this.laterType = FileSystemEntityType.notFound});
  final File journal;
  final Object? probeError;
  final FileSystemEntityType laterType;
  final log = <String>[];
  var probes = 0;
  var lookups = 0;

  Future<void> run(Future<void> Function() body) async {
    final parent = Zone.current;
    final selected = journal.absolute.uri;
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
