import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Real temporary files, CharacterLibrary and SQLite. Only the start of a
// selected real characters-directory list is gated; other IO is delegated.
// No production hook, elapsed-time sleep, delete retry or external service.
void main() {
  test('canceling a watcher does not let close return before its accepted file snapshot', () async {
    await _withFixture((h) async {
      final gate = h.io.holdNext(skip: 1); // _tidy lists first, then the actual summary scan.
      final watch = h.watch();
      await gate.entered.future.timeout(_deadline);
      await watch.subscription.cancel();
      var closed = false;
      final closing = h.track(h.engine.close().then((_) => closed = true));
      await _eventTurn();
      expect(closed, isFalse);
      expect(h.io.activeLists, 1);
      gate.release();
      await closing.timeout(_deadline);
      expect(h.io.activeLists, 0);
      expect(watch.values, isEmpty);
      expect(watch.errors, isEmpty);
      await h.root.delete(recursive: true);
      expect(await h.root.exists(), isFalse);
    });
  });

  for (final paused in [false, true]) {
    test('close drains file work without waiting for a ${paused ? 'paused' : 'live'} UI subscriber', () async {
      await _withFixture((h) async {
        final gate = h.io.holdNext(skip: 1);
        final watch = h.watch(paused: paused);
        await gate.entered.future.timeout(_deadline);
        var closed = false;
        final closing = h.track(h.engine.close().then((_) => closed = true));
        await _eventTurn();
        expect(closed, isFalse);
        gate.release();
        // Deliberately do not cancel/resume the UI subscription until after
        // close. Its notification stream must not own the filesystem drain.
        await closing.timeout(_deadline);
        expect(h.io.activeLists, 0);
        expect(watch.values, isEmpty);
        expect(watch.errors, isEmpty);
        if (paused) {
          expect(watch.done.isCompleted, isFalse);
        } else {
          await watch.done.future.timeout(_deadline);
        }
        await watch.subscription.cancel();
        await h.root.delete(recursive: true);
      });
    });
  }

  test('streams created before close cannot start a snapshot when listened during or after close', () async {
    await _withFixture((h) async {
      final during = h.engine.watchCharacters();
      final after = h.engine.watchCharacters();
      final creates = h.io.createCalls;
      final lists = h.io.listCalls;
      final closing = h.track(h.engine.close());
      final first = h.watch(stream: during);
      await closing.timeout(_deadline);
      final second = h.watch(stream: after);
      await Future.wait([first.done.future, second.done.future]).timeout(_deadline);
      expect(h.io.createCalls, creates);
      expect(h.io.listCalls, lists);
      expect(first.values, isEmpty);
      expect(second.values, isEmpty);
      expect(first.errors, isEmpty);
      expect(second.errors, isEmpty);
    });
  });

  test('a real listing failure during the drain does not strand close or publish a late watcher error', () async {
    await _withFixture((h) async {
      final gate = h.io.holdNext(skip: 1);
      final watch = h.watch();
      await gate.entered.future.timeout(_deadline);
      await h.characters.rename('${h.workspace.path}/saved-characters');
      await File(h.characters.path).writeAsString('a file, not a directory');
      final closing = h.track(h.engine.close());
      gate.release();
      await closing.timeout(_deadline);
      expect(gate.finished.isCompleted, isTrue);
      expect(h.io.activeLists, 0);
      expect(watch.values, isEmpty);
      expect(watch.errors, isEmpty);
      await h.root.delete(recursive: true);
    });
  });

  test('backup drains an old summary recovery while its dirty refresh waits outside the capture barrier', () async {
    await _withFixture((h) async {
      final index = File('${h.root.path}/character-index/${h.characterId}.json');
      await index.delete();
      final reading = h.io.holdNext(skip: 1);
      final watch = h.watch();
      await reading.entered.future.timeout(_deadline);
      // The imported detail is cached, so creating this chat does not need
      // the blocked library list. Its change makes the current pump dirty.
      await h.engine.createChat(h.characterId);
      await _eventTurn();
      bool? recoveryFinishedBeforeCapture;
      final capture = h.io.holdNext(
        onEnter: () {
          recoveryFinishedBeforeCapture = reading.finished.isCompleted;
        },
      );
      final archive = File('${h.workspace.path}/old-reader.zip');
      final backingUp = h.track(h.engine.backup(archive.path));
      reading.release();
      await capture.entered.future.timeout(_deadline);
      expect(recoveryFinishedBeforeCapture, isTrue);
      expect(await index.exists(), isTrue);
      expect(watch.first.isCompleted, isFalse, reason: 'The dirty first snapshot must not be published.');
      capture.release();
      await backingUp.timeout(_deadline);
      final first = await watch.first.future.timeout(_deadline);
      expect(first, isA<List<TavernCharacter>>());
      expect((first as List<TavernCharacter>).single.chatCount, 1);
      expect(await archive.exists(), isTrue);
      expect(watch.errors, isEmpty);
    });
  });

  test('a new watcher during capture starts no file IO and resumes without a backup self-wait', () async {
    await _withFixture((h) async {
      final capture = h.io.holdNext();
      final archive = File('${h.workspace.path}/new-reader.zip');
      final backingUp = h.track(h.engine.backup(archive.path));
      await capture.entered.future.timeout(_deadline);
      final creates = h.io.createCalls;
      final lists = h.io.listCalls;
      final watch = h.watch();
      await _eventTurn();
      // _tidy.create is the first synchronous IO call in a new list action.
      // Observing it avoids any assumption about native IO completion speed.
      expect(h.io.createCalls, creates);
      expect(h.io.listCalls, lists);
      expect(watch.first.isCompleted, isFalse);
      capture.release();
      await backingUp.timeout(_deadline);
      final first = await watch.first.future.timeout(_deadline);
      expect((first as List<TavernCharacter>).single.id, h.characterId);
      expect(h.io.createCalls, greaterThan(creates));
      expect(watch.errors, isEmpty);
      expect(await archive.exists(), isTrue);
    });
  });

  test('a real capture failure releases delayed watchers and leaves their next read retryable', () async {
    await _withFixture((h) async {
      final capture = h.io.holdNext();
      final archive = File('${h.workspace.path}/failed-capture.zip');
      final backingUp = h.track(h.engine.backup(archive.path));
      await capture.entered.future.timeout(_deadline);
      final creates = h.io.createCalls;
      final watch = h.watch();
      await _eventTurn();
      expect(h.io.createCalls, creates);
      final moved = await h.characters.rename('${h.workspace.path}/saved-characters');
      final obstruction = File(h.characters.path);
      await obstruction.writeAsString('capture and delayed reader must report real IO failure');
      capture.release();
      await expectLater(backingUp, throwsA(isA<FileSystemException>()));
      final first = await watch.first.future.timeout(_deadline);
      expect(first, isA<FileSystemException>());
      expect(await archive.exists(), isFalse);
      await watch.subscription.cancel();
      await obstruction.delete();
      await moved.rename(h.characters.path);
      final retry = h.watch();
      final restored = await retry.first.future.timeout(_deadline);
      expect((restored as List<TavernCharacter>).single.id, h.characterId);
      expect(retry.errors, isEmpty);
      expect((await h.engine.character(h.characterId))!.name, 'Watch fixture');
    });
  });
}

const _deadline = Duration(seconds: 10);

// Flush already scheduled microtasks and one event turn; never wait an
// arbitrary elapsed duration to make a native file operation "probably done".
Future<void> _eventTurn() => Future<void>(() {});

Future<void> _withFixture(Future<void> Function(_Fixture fixture) body) async {
  final allocated = await Directory.systemTemp.createTemp('dsh-t24-watch-lifecycle-');
  final workspace = Directory(await allocated.resolveSymbolicLinks());
  final root = await Directory('${workspace.path}/tavern').create();
  final parentZone = Zone.current;
  final characters = Directory('${root.path}/characters');
  final target = characters.absolute.uri;
  final control = _ListControl();
  _Fixture? fixture;
  try {
    await IOOverrides.runZoned(
      () async {
        final engine = await TavernEngine.openDirectory(
          root,
          config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture'),
          modelClient: TavernModelClient(clientFactory: () => throw StateError('No model request is expected')),
          clock: () => DateTime.utc(2026, 11, 10),
          random: () => 0.25,
        );
        final h = _Fixture(workspace, root, characters, engine, control);
        fixture = h;
        final card = await engine.importCard(_card());
        h.characterId = card.id;
        try {
          await body(h);
        } finally {
          await h.dispose();
        }
      },
      createDirectory: (path) {
        // Construct the delegate outside this override to avoid recursion. URI
        // comparison only normalizes separators in these generated plain paths.
        final real = parentZone.run(() => Directory(path));
        final identity = parentZone.run(() => real.absolute.uri);
        return identity == target ? _GatedDirectory(real, control) : real;
      },
    );
  } finally {
    // Also covers an import/body setup failure before its inner finally.
    control.releaseAll();
    await fixture?.dispose();
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  }
}

class _Fixture {
  _Fixture(this.workspace, this.root, this.characters, this.engine, this.io);
  final Directory workspace;
  final Directory root;
  final Directory characters;
  final TavernEngine engine;
  final _ListControl io;
  late final String characterId;
  final watches = <_ObservedWatch>[];
  final pending = <Future<void>>[];
  Future<void>? _disposal;

  Future<T> track<T>(Future<T> future) {
    pending.add(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  _ObservedWatch watch({Stream<List<TavernCharacter>>? stream, bool paused = false}) {
    final result = _ObservedWatch(stream ?? engine.watchCharacters());
    watches.add(result);
    if (paused) {
      result.subscription.pause();
    }
    return result;
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    io.releaseAll();
    for (final watch in watches) {
      await watch.subscription.cancel();
    }
    // Retain the original operations even if an assertion's timeout fired.
    // Never close a database while a native backup has merely been abandoned.
    await Future.wait(pending);
    await engine.close();
    for (final gate in io.gates) {
      if (gate.entered.isCompleted) {
        await gate.finished.future;
      }
    }
  }
}

class _ObservedWatch {
  _ObservedWatch(Stream<List<TavernCharacter>> stream) {
    subscription = stream.listen(
      (value) {
        values.add(value);
        if (!first.isCompleted) {
          first.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        errors.add(error);
        if (!first.isCompleted) {
          first.complete(error);
        }
      },
      onDone: done.complete,
    );
  }

  late final StreamSubscription<List<TavernCharacter>> subscription;
  final values = <List<TavernCharacter>>[];
  final errors = <Object>[];
  final first = Completer<Object>();
  final done = Completer<void>();
}

class _ListGate {
  _ListGate(this.skip, this.onEnter);
  int skip;
  final void Function()? onEnter;
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();

  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }
}

class _ListControl {
  final gates = <_ListGate>[];
  final _waiting = <_ListGate>[];
  int createCalls = 0;
  int listCalls = 0;
  int activeLists = 0;

  _ListGate holdNext({int skip = 0, void Function()? onEnter}) {
    final gate = _ListGate(skip, onEnter);
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
    listCalls++;
    activeLists++;
    _ListGate? gate;
    if (_waiting.isNotEmpty) {
      if (_waiting.first.skip == 0) {
        gate = _waiting.removeAt(0);
      } else {
        _waiting.first.skip--;
      }
    }
    try {
      if (gate != null) {
        gate.onEnter?.call();
        gate.entered.complete();
        await gate._released.future;
      }
      yield* real.list(recursive: recursive, followLinks: followLinks);
    } finally {
      activeLists--;
      gate?.finished.complete();
    }
  }
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
  Future<Directory> create({bool recursive = false}) {
    control.createCalls++;
    return real.create(recursive: recursive);
  }

  @override
  void createSync({bool recursive = false}) => real.createSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) => real.createTemp(prefix);
  @override
  Directory createTempSync([String? prefix]) => real.createTempSync(prefix);
  @override
  Future<String> resolveSymbolicLinks() => real.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => real.resolveSymbolicLinksSync();
  @override
  Future<Directory> rename(String newPath) => real.rename(newPath);
  @override
  Directory renameSync(String newPath) => real.renameSync(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  void deleteSync({bool recursive = false}) => real.deleteSync(recursive: recursive);
  @override
  Future<FileStat> stat() => real.stat();
  @override
  FileStat statSync() => real.statSync();
  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      real.watch(events: events, recursive: recursive);
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      control.list(real, recursive: recursive, followLinks: followLinks);
  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) =>
      real.listSync(recursive: recursive, followLinks: followLinks);
  @override
  String toString() => real.toString();
}

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Watch fixture',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'Hello',
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
