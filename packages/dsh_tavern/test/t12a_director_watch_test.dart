import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real engine, SQLite and character files. Gates control the start of real
// reads/listings, not their bytes or result. A file read count is not a count
// of SQL/hash work: the pre-existing character-detail cache also shares IO.
void main() {
  test('unlistened director streams do not read a cold character or call the model', () async {
    await _withFixture((f) async {
      final first = f.engine.watchDirector(f.chatId);
      final second = f.engine.watchDirector(f.chatId);
      await _eventTurn();
      expect(f.reads.calls, 0);
      expect(f.lists.calls, 0);
      expect(f.h.model.generated, 0);
      await f.engine.close();
      final a = f.watch(stream: first);
      final b = f.watch(stream: second);
      await Future.wait([a.done.future, b.done.future]).timeout(_deadline);
      expect(a.values, isEmpty);
      expect(b.values, isEmpty);
      expect(a.errors, isEmpty);
      expect(b.errors, isEmpty);
      expect(f.reads.calls, 0);
      expect(() => f.engine.watchDirector(f.chatId), throwsStateError);
    }, cold: true);
  });

  test('two synchronous listeners receive one completed snapshot and cancellation is independent', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final a = f.watch();
      final b = f.watch();
      await gate.entered.future.timeout(_deadline);
      expect(a.values, isEmpty);
      expect(b.values, isEmpty);
      gate.release();
      final values = await Future.wait([a.next(), b.next()]).timeout(_deadline);
      // This identifies shared publication, not the number of discarded
      // read attempts or of SQL/hash operations hidden behind that snapshot.
      expect(values[0], same(values[1]));
      expect(values[0].chatId, f.chatId);
      expect(f.reads.calls, 1);
      await _eventTurn();
      await a.subscription.cancel();
      final seen = b.values.length;
      await f.setEnabled(true);
      expect((await b.next(from: seen, where: (value) => value.automaticEnabled)).automaticEnabled, isTrue);
      expect(a.values, hasLength(1));
      expect(a.errors, isEmpty);
      expect(b.errors, isEmpty);
      expect(f.h.model.generated, 0);
    }, cold: true);
  });

  test('different chats and an unknown-chat error stay isolated', () async {
    await _withFixture((f) async {
      final otherChat = await f.engine.createChat(f.h.characterId);
      final a = f.watch();
      final b = f.watch(chatId: otherChat);
      final bad = f.watch(chatId: 'missing-chat');
      await Future.wait([a.next(), b.next()]).timeout(_deadline);
      expect(await bad.nextError(), isA<StateError>());
      await _eventTurn();
      final beforeB = b.values.length;
      final beforeA = a.values.length;
      await f.setEnabled(true);
      final changed = await a.next(from: beforeA, where: (value) => value.automaticEnabled);
      await _eventTurn();
      expect(changed.chatId, f.chatId);
      expect(b.values, hasLength(beforeB));
      expect(b.values.every((value) => value.chatId == otherChat && !value.automaticEnabled), isTrue);
      expect(a.errors, isEmpty);
      expect(b.errors, isEmpty);
      expect(bad.values, isEmpty);
      expect(f.h.model.generated, 0);
    });
  });

  test('pausing one listener does not buffer intermediate snapshots or pause its peer', () async {
    await _withFixture((f) async {
      final a = f.watch();
      final b = f.watch();
      await Future.wait([a.next(), b.next()]).timeout(_deadline);
      // The initial event and scheduled callbacks have drained before pause.
      await _eventTurn();
      final beforeA = a.values.length;
      a.subscription.pause();
      for (final enabled in [true, false, true]) {
        final beforeB = b.values.length;
        await f.setEnabled(enabled);
        await b.next(from: beforeB, where: (value) => value.automaticEnabled == enabled);
      }
      await _eventTurn();
      expect(a.values, hasLength(beforeA));
      a.subscription.resume();
      await a.next(from: beforeA, where: (value) => value.automaticEnabled);
      await _eventTurn();
      expect(a.values.skip(beforeA).map((value) => value.automaticEnabled), [true]);
      expect(a.errors, isEmpty);
      expect(b.errors, isEmpty);
    });
  });

  test('all paused listeners start no cold read and resume only the current view', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final a = f.watch(paused: true);
      final b = f.watch(paused: true);
      for (final enabled in [true, false, true]) {
        await f.setEnabled(enabled);
      }
      await _eventTurn();
      expect(f.reads.calls, 0);
      expect(f.lists.calls, 0);
      expect(gate.entered.isCompleted, isFalse);
      a.subscription.resume();
      await gate.entered.future.timeout(_deadline);
      gate.release();
      expect((await a.next()).automaticEnabled, isTrue);
      await _eventTurn();
      expect(a.values, hasLength(1));
      expect(b.values, isEmpty);
      b.subscription.resume();
      expect((await b.next()).automaticEnabled, isTrue);
      await _eventTurn();
      expect(b.values, hasLength(1));
      expect(f.h.model.generated, 0);
    }, cold: true);
  });

  test('all previously active listeners stay idle after their character detail is evicted', () async {
    await _withFixture((f) async {
      final a = f.watch();
      final b = f.watch();
      await Future.wait([a.next(), b.next()]).timeout(_deadline);
      await _eventTurn();
      final beforeA = a.values.length;
      final beforeB = b.values.length;
      a.subscription.pause();
      b.subscription.pause();
      // The established detail cache has capacity eight. Real imports of
      // eight other characters make this already-observed card cold again.
      for (var index = 0; index < 8; index++) {
        await f.engine.importCard(t24Card());
      }
      final gate = f.reads.holdNext();
      for (final enabled in [true, false, true]) {
        await f.setEnabled(enabled);
      }
      await _eventTurn();
      expect(f.reads.calls, 0);
      expect(a.values, hasLength(beforeA));
      expect(b.values, hasLength(beforeB));
      a.subscription.resume();
      await gate.entered.future.timeout(_deadline);
      gate.release();
      expect((await a.next(from: beforeA)).automaticEnabled, isTrue);
      await _eventTurn();
      expect(a.values.skip(beforeA).map((value) => value.automaticEnabled), [true]);
      expect(b.values, hasLength(beforeB));
      expect(f.h.model.generated, 0);
    });
  });

  test('pause during an admitted read prevents publication until a fresh resume', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final watch = f.watch();
      await gate.entered.future.timeout(_deadline);
      watch.subscription.pause();
      gate.release();
      await gate.finished.future.timeout(_deadline);
      // readDirector awaits the same cached record and then completes its
      // own full snapshot, so the native record read has really settled.
      await f.engine.readDirector(f.chatId);
      await _eventTurn();
      expect(watch.values, isEmpty);
      f.writeEnabledWithoutNotification(true);
      watch.subscription.resume();
      expect((await watch.next()).automaticEnabled, isTrue);
      await _eventTurn();
      expect(watch.values, hasLength(1));
    }, cold: true);
  });

  test('a resumeSignal after immediate pause admits a current cold read', () async {
    await _withFixture((f) async {
      final resumed = Completer<void>();
      final gate = f.reads.holdNext();
      final watch = f.watch();
      watch.subscription.pause(resumed.future);
      await f.setEnabled(true);
      await _eventTurn();
      expect(f.reads.calls, 0);
      resumed.complete();
      await gate.entered.future.timeout(_deadline);
      gate.release();
      expect((await watch.next()).automaticEnabled, isTrue);
      expect(watch.errors, isEmpty);
    }, cold: true);
  });

  test('pausing from a data callback and later resuming reads a fresh saved view', () async {
    await _withFixture((f) async {
      var paused = false;
      final watch = f.watch(
        onValue: (observer, value) {
          if (!paused) {
            paused = true;
            observer.subscription.pause();
          }
        },
      );
      await watch.next();
      await _eventTurn();
      final before = watch.values.length;
      f.writeEnabledWithoutNotification(true);
      watch.subscription.resume();
      expect((await watch.next(from: before)).automaticEnabled, isTrue);
      await _eventTurn();
      expect(watch.values, hasLength(before + 1));
      expect(watch.errors, isEmpty);
    });
  });

  test('an immediate pause and resume inside a data callback does not strand later notifications', () async {
    await _withFixture((f) async {
      var changedPause = false;
      final watch = f.watch(
        onValue: (observer, value) {
          if (!changedPause) {
            changedPause = true;
            observer.subscription.pause();
            observer.subscription.resume();
          }
        },
      );
      await watch.next();
      await _eventTurn();
      final before = watch.values.length;
      await f.setEnabled(true);
      expect((await watch.next(from: before, where: (value) => value.automaticEnabled)).automaticEnabled, isTrue);
      expect(watch.errors, isEmpty);
    });
  });

  test('a resumeSignal releases only one of two nested pauses', () async {
    await _withFixture((f) async {
      final resumed = Completer<void>();
      final gate = f.reads.holdNext();
      final watch = f.watch(paused: true);
      watch.subscription.pause(resumed.future);
      await f.setEnabled(true);
      resumed.complete();
      await _eventTurn();
      expect(watch.subscription.isPaused, isTrue);
      expect(f.reads.calls, 0);
      watch.subscription.resume();
      await gate.entered.future.timeout(_deadline);
      gate.release();
      expect((await watch.next()).automaticEnabled, isTrue);
      expect(watch.errors, isEmpty);
    }, cold: true);
  });

  test('a newly attached listener refreshes saved state without a store notification', () async {
    await _withFixture((f) async {
      final a = f.watch();
      expect((await a.next()).automaticEnabled, isFalse);
      await _eventTurn();
      final before = a.values.length;
      f.writeEnabledWithoutNotification(true);
      await _eventTurn();
      expect(a.values, hasLength(before), reason: 'External SQLite writes do not emit this store instance changes.');
      final b = f.watch();
      expect((await b.next()).automaticEnabled, isTrue);
      expect((await a.next(from: before)).automaticEnabled, isTrue);
      expect(b.values, hasLength(1));
      expect(f.h.model.generated, 0);
    });
  });

  test('resume refreshes saved state without any new store notification', () async {
    await _withFixture((f) async {
      final watch = f.watch();
      expect((await watch.next()).automaticEnabled, isFalse);
      await _eventTurn();
      final before = watch.values.length;
      watch.subscription.pause();
      f.writeEnabledWithoutNotification(true);
      await _eventTurn();
      expect(watch.values, hasLength(before));
      watch.subscription.resume();
      expect((await watch.next(from: before)).automaticEnabled, isTrue);
      await _eventTurn();
      expect(watch.values, hasLength(before + 1));
    });
  });

  test('a listener joining a cold in-flight read receives the final dirty state', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final a = f.watch();
      await gate.entered.future.timeout(_deadline);
      await f.setEnabled(true);
      final b = f.watch();
      await _eventTurn();
      gate.release();
      final values = await Future.wait([a.next(), b.next()]).timeout(_deadline);
      expect(values.every((value) => value.automaticEnabled), isTrue);
      expect(values[0], same(values[1]));
      await _eventTurn();
      expect(a.values, hasLength(1));
      expect(b.values, hasLength(1));
      expect(f.h.model.generated, 0);
    }, cold: true);
  });

  test('last cancellation retires an in-flight hub without deleting its replacement', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final retired = f.watch();
      await gate.entered.future.timeout(_deadline);
      await retired.subscription.cancel().timeout(_deadline);
      expect(gate.finished.isCompleted, isFalse, reason: 'Cancellation does not pretend to cancel native IO.');
      final successor = f.watch();
      await f.setEnabled(true);
      await _eventTurn();
      gate.release();
      expect((await successor.next()).automaticEnabled, isTrue);
      await _eventTurn();
      final before = successor.values.length;
      await f.setEnabled(false);
      expect((await successor.next(from: before, where: (value) => !value.automaticEnabled)).automaticEnabled, isFalse);
      expect(retired.values, isEmpty);
      expect(retired.errors, isEmpty);
      expect(successor.errors, isEmpty);
      expect(f.h.model.generated, 0);
    }, cold: true);
  });

  test('cancelled last listener leaves its admitted cold IO owned by engine close', () async {
    await _withFixture((f) async {
      final gate = f.reads.holdNext();
      final watch = f.watch();
      await gate.entered.future.timeout(_deadline);
      await watch.subscription.cancel().timeout(_deadline);
      var closed = false;
      final closing = f.track(f.engine.close().then((_) => closed = true));
      await _eventTurn();
      expect(closed, isFalse);
      expect(f.reads.active, 1);
      await expectLater(TavernEngine.openDirectory(f.h.root), throwsStateError);
      gate.release();
      await closing.timeout(_deadline);
      expect(f.reads.active, 0);
      expect(watch.values, isEmpty);
      expect(watch.errors, isEmpty);
      final reopened = await TavernEngine.openDirectory(f.h.root);
      await reopened.close();
    }, cold: true);
  });

  for (final paused in [false, true]) {
    test('engine close drains admitted IO without waiting for a ${paused ? 'paused' : 'live'} director UI', () async {
      await _withFixture((f) async {
        final gate = f.reads.holdNext();
        final watch = f.watch();
        await gate.entered.future.timeout(_deadline);
        if (paused) watch.subscription.pause();
        var closed = false;
        final closing = f.track(f.engine.close().then((_) => closed = true));
        await _eventTurn();
        expect(closed, isFalse);
        gate.release();
        await closing.timeout(_deadline);
        expect(f.reads.active, 0);
        expect(watch.values, isEmpty);
        expect(watch.errors, isEmpty);
        if (paused) {
          expect(watch.done.isCompleted, isFalse);
          watch.subscription.resume();
        }
        await watch.done.future.timeout(_deadline);
      }, cold: true);
    });
  }

  for (final resume in [false, true]) {
    test(
      '${resume ? 'resuming' : 'creating'} a watch inside backup capture waits outside admitted operations',
      () async {
        await _withFixture((f) async {
          final paused = resume ? f.watch(paused: true) : null;
          final capture = f.lists.holdNext();
          final archive = File('${f.workspace.path}/capture-${resume ? 'resume' : 'new'}.zip');
          final backup = f.track(f.engine.backup(archive.path));
          await capture.entered.future.timeout(_deadline);
          final listCalls = f.lists.calls;
          final watch = paused ?? f.watch();
          paused?.subscription.resume();
          await _eventTurn();
          expect(f.reads.calls, 0);
          expect(f.lists.calls, listCalls);
          expect(watch.values, isEmpty);
          capture.release();
          await backup.timeout(_deadline);
          expect((await watch.next()).chatId, f.chatId);
          expect(await archive.exists(), isTrue);
          expect(watch.errors, isEmpty);
          expect(f.h.model.generated, 0);
        }, cold: true);
      },
    );
  }

  test('backup drains an admitted read after cancellation and its successor waits for capture', () async {
    await _withFixture((f) async {
      final reading = f.reads.holdNext();
      final old = f.watch();
      await reading.entered.future.timeout(_deadline);
      await old.subscription.cancel().timeout(_deadline);
      bool? drainedBeforeCapture;
      final capture = f.lists.holdNext(
        onEnter: () {
          drainedBeforeCapture = reading.finished.isCompleted && f.reads.active == 0;
        },
      );
      final archive = File('${f.workspace.path}/drained-reader.zip');
      final backup = f.track(f.engine.backup(archive.path));
      await _eventTurn();
      expect(capture.entered.isCompleted, isFalse);
      reading.release();
      await capture.entered.future.timeout(_deadline);
      expect(drainedBeforeCapture, isTrue);
      final successor = f.watch();
      await _eventTurn();
      expect(successor.values, isEmpty);
      capture.release();
      await backup.timeout(_deadline);
      expect((await successor.next()).chatId, f.chatId);
      expect(old.values, isEmpty);
      expect(old.errors, isEmpty);
      expect(successor.errors, isEmpty);
      expect(await archive.exists(), isTrue);
    }, cold: true);
  });

  test('a dirty admitted read drains before capture while its live refresh waits outside the gate', () async {
    await _withFixture((f) async {
      final reading = f.reads.holdNext();
      final watch = f.watch();
      await reading.entered.future.timeout(_deadline);
      await f.setEnabled(true);
      await _eventTurn();
      bool? drainedBeforeCapture;
      final capture = f.lists.holdNext(
        onEnter: () {
          drainedBeforeCapture = reading.finished.isCompleted && f.reads.active == 0;
        },
      );
      final archive = File('${f.workspace.path}/dirty-reader.zip');
      final backup = f.track(f.engine.backup(archive.path));
      await _eventTurn();
      expect(capture.entered.isCompleted, isFalse);
      reading.release();
      await capture.entered.future.timeout(_deadline);
      expect(drainedBeforeCapture, isTrue);
      await _eventTurn();
      expect(watch.values, isEmpty, reason: 'Neither the dirty first read nor the gated refresh may publish.');
      expect(watch.errors, isEmpty);
      expect(f.reads.calls, 1, reason: 'Native IO count only; the record cache is already warm.');
      capture.release();
      await backup.timeout(_deadline);
      expect((await watch.next()).automaticEnabled, isTrue);
      await _eventTurn();
      expect(watch.values, hasLength(1));
      expect(watch.errors, isEmpty);
      expect(await archive.exists(), isTrue);
    }, cold: true);
  });

  test('closing a watch waiting outside capture never starts a late character read', () async {
    await _withFixture((f) async {
      final capture = f.lists.holdNext();
      final archive = File('${f.workspace.path}/closing-capture.zip');
      final backup = f.track(f.engine.backup(archive.path));
      await capture.entered.future.timeout(_deadline);
      final watch = f.watch();
      await _eventTurn();
      expect(f.reads.calls, 0);
      var closed = false;
      final closing = f.track(f.engine.close().then((_) => closed = true));
      await _eventTurn();
      expect(closed, isFalse, reason: 'The backup still owns its genuine capture IO.');
      capture.release();
      await Future.wait<void>([backup.then<void>((_) {}), closing.then<void>((_) {})]).timeout(_deadline);
      await watch.done.future.timeout(_deadline);
      expect(f.reads.calls, 0);
      expect(watch.values, isEmpty);
      expect(watch.errors, isEmpty);
      expect(await archive.exists(), isTrue);
    }, cold: true);
  });

  test('failed real capture releases a delayed watch and the same watch can retry', () async {
    await _withFixture((f) async {
      final capture = f.lists.holdNext();
      final archive = File('${f.workspace.path}/failed-capture.zip');
      final backup = f.track(f.engine.backup(archive.path));
      await capture.entered.future.timeout(_deadline);
      final watch = f.watch();
      await _eventTurn();
      expect(f.reads.calls, 0);
      final moved = await f.characters.rename('${f.workspace.path}/saved-characters');
      final obstruction = File(f.characters.path);
      // The delayed watch fails in read -> _tidy -> Directory.create,
      // before _read can treat a missing character directory as null.
      await obstruction.writeAsString('a regular file cannot be the characters directory');
      capture.release();
      await expectLater(backup, throwsA(isA<FileSystemException>()));
      expect(await watch.nextError(), isA<FileSystemException>());
      expect(await archive.exists(), isFalse);
      await obstruction.delete();
      await moved.rename(f.characters.path);
      await f.setEnabled(true);
      expect((await watch.next(where: (value) => value.automaticEnabled)).automaticEnabled, isTrue);
      expect(watch.errors, hasLength(1));
      expect(f.h.model.generated, 0);
    }, cold: true);
  });

  test('a real cold read error reaches both live listeners and a change retries the same hub', () async {
    await _withFixture((f) async {
      final bytes = await f.cardFile.readAsBytes();
      final gate = f.reads.holdNext();
      final a = f.watch();
      final b = f.watch();
      await gate.entered.future.timeout(_deadline);
      await f.cardFile.delete();
      gate.release();
      final errors = await Future.wait([a.nextError(), b.nextError()]).timeout(_deadline);
      expect(errors.every((error) => error is FileSystemException), isTrue);
      expect(a.values, isEmpty);
      expect(b.values, isEmpty);
      await f.cardFile.writeAsBytes(bytes, flush: true);
      await f.setEnabled(true);
      final values = await Future.wait([
        a.next(where: (value) => value.automaticEnabled),
        b.next(where: (value) => value.automaticEnabled),
      ]).timeout(_deadline);
      expect(values[0], same(values[1]));
      expect(a.errors, hasLength(1));
      expect(b.errors, hasLength(1));
      expect(f.reads.calls, 2);
    }, cold: true);
  });

  test('an error from a dirtied read is discarded before a controlled retry succeeds', () async {
    await _withFixture((f) async {
      final bytes = await f.cardFile.readAsBytes();
      final first = f.reads.holdNext();
      final second = f.reads.holdNext();
      final watch = f.watch();
      await first.entered.future.timeout(_deadline);
      await f.cardFile.delete();
      await f.setEnabled(true);
      await _eventTurn();
      first.release();
      await second.entered.future.timeout(_deadline);
      expect(first.finished.isCompleted, isTrue);
      expect(watch.values, isEmpty);
      expect(watch.errors, isEmpty);
      await f.cardFile.writeAsBytes(bytes, flush: true);
      second.release();
      expect((await watch.next()).automaticEnabled, isTrue);
      expect(watch.errors, isEmpty);
      expect(f.reads.calls, 2);
    }, cold: true);
  });

  test('paused UI receives no queued read error and resume reads the repaired file', () async {
    await _withFixture((f) async {
      final bytes = await f.cardFile.readAsBytes();
      final gate = f.reads.holdNext();
      final paused = f.watch();
      final live = f.watch();
      await gate.entered.future.timeout(_deadline);
      paused.subscription.pause();
      await f.cardFile.delete();
      gate.release();
      expect(await live.nextError(), isA<FileSystemException>());
      expect(paused.errors, isEmpty);
      await f.cardFile.writeAsBytes(bytes, flush: true);
      paused.subscription.resume();
      expect((await paused.next()).chatId, f.chatId);
      await _eventTurn();
      expect(paused.errors, isEmpty);
      expect(live.errors, hasLength(1));
      expect(f.reads.calls, 2);
    }, cold: true);
  });

  test('shared story and event views are detached and reading never settles their true conditions', () async {
    await _withFixture((f) async {
      final raw = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
      (raw['data']! as Map<String, Object?>)['extensions'] = {
        'dshgo': {
          'v': 1,
          'story': {
            'acts': [
              {'id': 'start', 'when': true},
            ],
            'endings': [
              {'id': 'unused', 'title': 'Not executed by reading', 'when': true},
            ],
          },
          'director': {
            'eventRules': {
              'v': 1,
              'rules': [
                {
                  'id': 'notice',
                  'name': 'fixed',
                  'when': true,
                  'once': true,
                  'do': [
                    {'type': 'notice', 'text': 'NOT-EXECUTED-BY-READ'},
                  ],
                },
              ],
            },
          },
        },
      };
      final card = await f.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
      final chat = await f.engine.createChat(card.id);
      final before = f.savedRows();
      final a = f.watch(chatId: chat);
      final b = f.watch(chatId: chat);
      final snapshots = await Future.wait([a.next(), b.next()]).timeout(_deadline);
      expect(snapshots[0], same(snapshots[1]));
      final expectedStory = snapshots[1].story!;
      final expectedEvents = snapshots[1].eventRules!;
      expect(expectedStory['initialized'], isFalse);
      expect(expectedEvents['initialized'], isFalse);
      final changedStory = snapshots[0].story!;
      changedStory['initialized'] = true;
      (changedStory['unlockedEndings']! as List<Object?>).add('caller-only');
      final changedEvents = snapshots[0].eventRules!;
      changedEvents['initialized'] = true;
      (changedEvents['consumed']! as List<Object?>).add({'eventId': 'caller', 'handlerId': 'caller'});
      snapshots[0].issues.add({'code': 'caller-only'});
      expect(snapshots[1].story, expectedStory);
      expect(snapshots[1].eventRules, expectedEvents);
      expect(snapshots[1].issues, isEmpty);
      final fresh = await f.engine.readDirector(chat);
      expect(fresh.story, expectedStory);
      expect(fresh.eventRules, expectedEvents);
      expect(f.savedRows(), before);
      expect(f.h.model.generated, 0);
    });
  });
}

const _deadline = Duration(seconds: 10);
Future<void> _eventTurn() => Future<void>(() {});

Future<void> _withFixture(Future<void> Function(_Fixture fixture) body, {bool cold = false}) async {
  final h = await T24Harness.open(thinking: false);
  final workspace = await Directory.systemTemp.createTemp('dsh-t12a-watch-output-');
  final f = _Fixture(h, workspace);
  final parent = Zone.current;
  try {
    if (cold) await h.reopen();
    await _eventTurn();
    final canonical = await h.root.resolveSymbolicLinks();
    final cardUris = {f.cardFile.absolute.uri, File('$canonical/characters/${h.characterId}/card.json').absolute.uri};
    final charactersUris = {f.characters.absolute.uri, Directory('$canonical/characters').absolute.uri};
    await IOOverrides.runZoned(
      () => body(f),
      createFile: (path) {
        final real = parent.run(() => File(path));
        return cardUris.contains(parent.run(() => real.absolute.uri)) ? _GatedFile(real, f.reads) : real;
      },
      createDirectory: (path) {
        final real = parent.run(() => Directory(path));
        return charactersUris.contains(parent.run(() => real.absolute.uri)) ? _GatedDirectory(real, f.lists) : real;
      },
    );
  } finally {
    f.reads.releaseAll();
    f.lists.releaseAll();
    for (final watch in f.watches) {
      await watch.subscription.cancel();
    }
    // Timed-out assertions must not abandon native backup/read ownership.
    await Future.wait(f.pending);
    await h.dispose();
    if (await workspace.exists()) await workspace.delete(recursive: true);
  }
}

class _Fixture {
  _Fixture(this.h, this.workspace)
    : cardFile = File('${h.root.path}/characters/${h.characterId}/card.json'),
      characters = Directory('${h.root.path}/characters');
  final T24Harness h;
  final Directory workspace;
  final File cardFile;
  final Directory characters;
  final reads = _ReadControl();
  final lists = _ListControl();
  final watches = <_ObservedWatch>[];
  final pending = <Future<void>>[];
  TavernEngine get engine => h.engine;
  String get chatId => h.chatId;

  Future<T> track<T>(Future<T> future) {
    pending.add(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  _ObservedWatch watch({
    String? chatId,
    Stream<TavernDirectorSnapshot>? stream,
    bool paused = false,
    void Function(_ObservedWatch observer, TavernDirectorSnapshot value)? onValue,
  }) {
    final result = _ObservedWatch(stream ?? engine.watchDirector(chatId ?? this.chatId), onValue: onValue);
    watches.add(result);
    if (paused) result.subscription.pause();
    return result;
  }

  Future<void> setEnabled(bool enabled) => engine.setSettings({
    'director': {'enabled': enabled},
  }, chatId: chatId);

  void writeEnabledWithoutNotification(bool enabled) => _database((database) {
    final settings =
        jsonDecode(database.select('SELECT settings FROM chats WHERE id = ?', [chatId]).single['settings']! as String)
            as Map<String, Object?>;
    settings['director'] = {'enabled': enabled};
    database.execute('UPDATE chats SET settings = ? WHERE id = ?', [jsonEncode(settings), chatId]);
  });

  Map<String, Object?> savedRows() => _database(
    (database) => {
      for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
        table: [
          for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
        ],
    },
  );

  T _database<T>(T Function(Database database) action) {
    final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
    try {
      return action(database);
    } finally {
      database.close();
    }
  }
}

class _ObservedWatch {
  _ObservedWatch(
    Stream<TavernDirectorSnapshot> stream, {
    void Function(_ObservedWatch observer, TavernDirectorSnapshot value)? onValue,
  }) {
    subscription = stream.listen(
      (value) {
        values.add(value);
        onValue?.call(this, value);
        for (final waiter in _values.toList()) {
          if (values.length > waiter.from && waiter.where(value)) {
            _values.remove(waiter);
            waiter.result.complete(value);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        errors.add(error);
        for (final waiter in _errors.toList()) {
          if (errors.length > waiter.from) {
            _errors.remove(waiter);
            waiter.result.complete(error);
          }
        }
      },
      onDone: done.complete,
    );
  }

  late final StreamSubscription<TavernDirectorSnapshot> subscription;
  final values = <TavernDirectorSnapshot>[];
  final errors = <Object>[];
  final done = Completer<void>();
  final _values = <_ValueWaiter>[];
  final _errors = <_ErrorWaiter>[];

  Future<TavernDirectorSnapshot> next({int from = 0, bool Function(TavernDirectorSnapshot value)? where}) {
    final predicate = where ?? (_) => true;
    for (final value in values.skip(from)) {
      if (predicate(value)) return Future.value(value);
    }
    final waiter = _ValueWaiter(from, predicate);
    _values.add(waiter);
    return waiter.result.future.timeout(_deadline);
  }

  Future<Object> nextError({int from = 0}) {
    if (errors.length > from) return Future.value(errors[from]);
    final waiter = _ErrorWaiter(from);
    _errors.add(waiter);
    return waiter.result.future.timeout(_deadline);
  }
}

class _ValueWaiter {
  _ValueWaiter(this.from, this.where);
  final int from;
  final bool Function(TavernDirectorSnapshot value) where;
  final result = Completer<TavernDirectorSnapshot>();
}

class _ErrorWaiter {
  _ErrorWaiter(this.from);
  final int from;
  final result = Completer<Object>();
}

class _Gate {
  _Gate(this.onEnter);
  final void Function()? onEnter;
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class _ReadControl {
  final gates = <_Gate>[];
  final _waiting = <_Gate>[];
  int calls = 0;
  int active = 0;

  _Gate holdNext() {
    final gate = _Gate(null);
    gates.add(gate);
    _waiting.add(gate);
    return gate;
  }

  void releaseAll() {
    for (final gate in gates) {
      gate.release();
    }
  }

  Future<T> read<T>(Future<T> Function() action) async {
    calls++;
    active++;
    final gate = _waiting.isEmpty ? null : _waiting.removeAt(0);
    try {
      if (gate != null) {
        gate.entered.complete();
        await gate._released.future;
      }
      return await action();
    } finally {
      active--;
      gate?.finished.complete();
    }
  }
}

class _ListControl {
  final gates = <_Gate>[];
  final _waiting = <_Gate>[];
  int calls = 0;

  _Gate holdNext({void Function()? onEnter}) {
    final gate = _Gate(onEnter);
    gates.add(gate);
    _waiting.add(gate);
    return gate;
  }

  void releaseAll() {
    for (final gate in gates) {
      gate.release();
    }
  }

  Stream<FileSystemEntity> list(Directory real, {required bool recursive, required bool followLinks}) async* {
    calls++;
    final gate = _waiting.isEmpty ? null : _waiting.removeAt(0);
    try {
      if (gate != null) {
        gate.onEnter?.call();
        gate.entered.complete();
        await gate._released.future;
      }
      yield* real.list(recursive: recursive, followLinks: followLinks);
    } finally {
      gate?.finished.complete();
    }
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.control);
  final File real;
  final _ReadControl control;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  File get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<File> copy(String newPath) => real.copy(newPath);
  @override
  Future<Uint8List> readAsBytes() => control.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => control.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedDirectory implements Directory {
  _GatedDirectory(this.real, this.control);
  final Directory real;
  final _ListControl control;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  Directory get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) => real.create(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) => real.createTemp(prefix);
  @override
  Future<String> resolveSymbolicLinks() => real.resolveSymbolicLinks();
  @override
  Future<Directory> rename(String newPath) => real.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      control.list(real, recursive: recursive, followLinks: followLinks);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
