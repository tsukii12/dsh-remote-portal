import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Pause genuine file reads. The gate changes their scheduling, not their
// contents or the production parser/store. No elapsed-time race is assumed.
void main() {
  test('close keeps an uncached director character read and the directory reservation owned until it drains', () async {
    final h = await _open();
    await h.reopen();
    final gate = _ReadGate();
    await _withGates(h, {'${h.root.path}/characters/${h.characterId}/card.json': gate}, () async {
      final run = h.engine.runDirector(h.chatId);
      await gate.entered.future.timeout(_deadline);
      var closed = false;
      final closing = h.engine.close();
      unawaited(
        closing.then<void>((_) {
          closed = true;
        }),
      );
      expect((await run.timeout(_deadline)).success, isFalse);
      await _eventTurn();
      expect(closed, isFalse);
      expect(gate.finished.isCompleted, isFalse);
      await expectLater(TavernEngine.openDirectory(h.root), throwsStateError);
      gate.release();
      await closing.timeout(_deadline);
      expect(gate.finished.isCompleted, isTrue);
      expect(closed, isTrue);
      expect(h.model.generated, 0);
      final reopened = await TavernEngine.openDirectory(h.root);
      await reopened.close();
    });
  });

  test('cancelled book preparation drains its first real read and never admits the next bound book', () async {
    final h = await _open();
    await h.engine.putLorebook('first', {'entries': <String, Object?>{}});
    await h.engine.putLorebook('second', {'entries': <String, Object?>{}});
    await h.engine.bindLorebooks(['first', 'second']);
    await h.reopen();
    // Only the books should be uncached for this test.
    await h.engine.character(h.characterId);
    final first = _ReadGate();
    final second = _ReadGate()..release();
    await _withGates(
      h,
      {'${h.root.path}/lorebooks/first.json': first, '${h.root.path}/lorebooks/second.json': second},
      () async {
        final run = h.engine.runDirector(h.chatId);
        await first.entered.future.timeout(_deadline);
        var closed = false;
        final closing = h.engine.close();
        unawaited(
          closing.then<void>((_) {
            closed = true;
          }),
        );
        expect((await run.timeout(_deadline)).success, isFalse);
        await _eventTurn();
        expect(closed, isFalse);
        expect(second.reads, 0);
        first.release();
        await closing.timeout(_deadline);
        expect(first.finished.isCompleted, isTrue);
        expect(second.reads, 0);
        expect(h.model.generated, 0);
      },
    );
  });

  test('chat deletion drains cancelled local preparation and backup stays busy until that ownership ends', () async {
    final h = await _open();
    await h.reopen();
    final gate = _ReadGate();
    final work = await Directory.systemTemp.createTemp('dsh-t18-io-backup-');
    addTearDown(() => work.delete(recursive: true));
    await _withGates(h, {'${h.root.path}/characters/${h.characterId}/card.json': gate}, () async {
      final run = h.engine.runDirector(h.chatId);
      await gate.entered.future.timeout(_deadline);
      final deleting = h.engine.deleteChat(h.chatId);
      expect((await run.timeout(_deadline)).success, isFalse);
      await _eventTurn();
      final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
      try {
        expect(db.select('SELECT id FROM chats WHERE id = ?', [h.chatId]), hasLength(1));
      } finally {
        db.close();
      }
      final output = File('${work.path}/not-created.zip');
      await expectLater(
        h.engine.backup(output.path),
        throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.busy)),
      );
      expect(await output.exists(), isFalse);
      gate.release();
      await deleting.timeout(_deadline);
      expect(gate.finished.isCompleted, isTrue);
      expect(h.model.generated, 0);
      await expectLater(h.engine.path(h.chatId), throwsStateError);
      await h.engine.backup(output.path);
      expect(await output.exists(), isTrue);
    });
  });
}

const _deadline = Duration(seconds: 10);
Future<void> _eventTurn() => Future<void>(() {});

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

Future<void> _withGates(T24Harness h, Map<String, _ReadGate> paths, Future<void> Function() body) async {
  final parent = Zone.current;
  final gates = {for (final entry in paths.entries) File(entry.key).absolute.uri: entry.value};
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        final gate = gates[parent.run(() => real.absolute.uri)];
        return gate == null ? real : _GatedFile(real, gate);
      },
    );
  } finally {
    for (final gate in gates.values) {
      gate.release();
    }
    await h.engine.close();
  }
}

class _ReadGate {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  var reads = 0;
  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  Future<T> read<T>(Future<T> Function() action) async {
    reads++;
    if (!entered.isCompleted) {
      entered.complete();
    }
    try {
      await _released.future;
      return await action();
    } finally {
      if (!finished.isCompleted) {
        finished.complete();
      }
    }
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.gate);
  final File real;
  final _ReadGate gate;
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
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
