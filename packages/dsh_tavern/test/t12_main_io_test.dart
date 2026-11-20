import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Public facade, real files and SQLite. Only the scheduling of genuine File
// reads changes. No SQL fixture, production hook or provider call is needed.
// The optional old-product probe changes waits/releases only, never assertions
// or file contents. Its timeout is not a successful negative-control result.
final _oldProductProbe = Platform.environment['DSH_T12_MAIN_IO_OLD_PRODUCT_PROBE'] == '1';
const _deadline = Duration(seconds: 10);

void main() {
  test('stop releases a cold policy read while close still owns its real I/O', () async {
    final h = await _open();
    final before = (await h.engine.path(h.chatId)).map((message) => message.nodeId).toList();
    await h.reopen();
    final character = '${h.root.path}/characters/${h.characterId}';
    final log = _eventLog();
    final card = _ReadGate('policy', log);
    final original = _ReadGate('original', log);
    await _withGates(
      h,
      {'$character/card.json': card, '$character/original.json': original},
      drain: () async {
        if (card.entered.isCompleted) await card.finished.future;
      },
      body: () async {
        final events = T24Events(h.engine.send(h.chatId, 'stop during policy admission'));
        await card.entered.future.timeout(_deadline);
        h.engine.stop(h.chatId);
        await _cancelled(events, log);
        expect(card.finished.isCompleted, isFalse);
        final close = _DrainReceipt<void>(h.engine.close(), 'close', [card], log);
        await _expectReserved(h.root, log);
        expect(close.returned, isFalse, reason: log.join(' -> '));
        card.release();
        await close.checked.timeout(_deadline);
        expect(card.successfulReads, 1);
        expect(original.constructed, isFalse);
        expect(h.model.generated, 0);
        await _reopenAfterDrain(h, before);
      },
    );
  });

  test('close owns a cancelled cold main card read through its later original file read', () async {
    final h = await _open();
    final before = (await h.engine.path(h.chatId)).map((message) => message.nodeId).toList();
    await h.reopen();
    // reopen creates a fresh detail cache. No character/helper/watch lookup
    // follows it; checking the original's existence cannot warm that cache.
    final character = '${h.root.path}/characters/${h.characterId}';
    expect(await File('$character/original.json').exists(), isTrue);
    final log = _eventLog();
    // Admission first reads policy authority only; gate the full detail read.
    final card = _ReadGate('card', log, skipReads: 1);
    final original = _ReadGate('original', log);
    await _withGates(
      h,
      {'$character/card.json': card, '$character/original.json': original},
      drain: () => _drainCharacter(card, original),
      body: () async {
        final events = T24Events(h.engine.send(h.chatId, 'cancel before the cold card returns'));
        await card.entered.future.timeout(_deadline);
        expect(card.reads, 1);
        expect(card.finished.isCompleted, isFalse);
        expect(original.reads, 0);
        expect(h.model.generated, 0);
        expect((await h.engine.inspectTurn(h.chatId))!.status, TavernInspectionStatus.preparing);

        final close = _DrainReceipt<void>(h.engine.close(), 'close', [card, original], log);
        await _cancelled(events, log);
        expect(
          card.finished.isCompleted,
          isFalse,
          reason: 'The terminal cancelled event must not wait for the original File future.',
        );
        expect(h.model.generated, 0);
        // In the old-product probe the exact same close postcondition below is
        // evaluated after close really returned, while both read gates stay held.
        if (_oldProductProbe) await close.checked.timeout(_deadline);

        await _expectReserved(h.root, log);
        expect(close.returned, isFalse, reason: log.join(' -> '));
        card.release();
        await original.entered.future.timeout(_deadline);
        expect(card.successfulReads, 1);
        expect(card.finished.isCompleted, isTrue);
        expect(original.reads, 1);
        expect(original.finished.isCompleted, isFalse);
        await _expectReserved(h.root, log);
        expect(close.returned, isFalse, reason: 'Owning only card.json is insufficient: ${log.join(' -> ')}');

        original.release();
        await close.checked.timeout(_deadline);
        expect(original.successfulReads, 1);
        expect(h.model.generated, 0);
        await _reopenAfterDrain(h, before);
      },
    );
  });

  test('a stopped main drains its first cold lorebook without admitting the second bound book', () async {
    final h = await _open();
    await h.engine.putLorebook('first', {'entries': <String, Object?>{}});
    await h.engine.putLorebook('second', {'entries': <String, Object?>{}});
    await h.engine.bindLorebooks(['first', 'second']);
    final before = (await h.engine.path(h.chatId)).map((message) => message.nodeId).toList();
    await h.reopen();
    // Only the role card is warmed. No list/read/export of either book occurs
    // after reopening, so both bindings must use their actual files.
    expect((await h.engine.character(h.characterId))!.id, h.characterId);
    final log = _eventLog();
    final first = _ReadGate('first-book', log);
    final second = _ReadGate('second-book', log);
    await _withGates(
      h,
      {'${h.root.path}/lorebooks/first.json': first, '${h.root.path}/lorebooks/second.json': second},
      drain: () => _drainBooks(first, second),
      body: () async {
        final events = T24Events(h.engine.send(h.chatId, 'cancel while the first book is reading'));
        await first.entered.future.timeout(_deadline);
        expect(first.reads, 1);
        expect(first.finished.isCompleted, isFalse);
        expect(second.constructed, isFalse);
        expect(second.reads, 0);
        h.engine.stop(h.chatId);
        await _cancelled(events, log);
        expect(first.finished.isCompleted, isFalse);
        expect((await h.engine.path(h.chatId)).map((message) => message.nodeId), before);

        final close = _DrainReceipt<void>(h.engine.close(), 'close', [first], log);
        await _expectReserved(h.root, log);
        expect(close.returned, isFalse, reason: log.join(' -> '));
        expect(second.reads, 0);
        first.release();
        // The old implementation continues its abandoned _loadBooks loop. Once
        // that forbidden read is observed, release it so the old queue snapshot
        // cannot turn this admission failure into a mere close timeout.
        if (_oldProductProbe) {
          await second.entered.future.timeout(_deadline);
          second.release();
        }
        await close.checked.timeout(_deadline);
        expect(first.successfulReads, 1);
        expect(
          second.reads,
          0,
          reason: 'A cancelled main must not admit book 2, even after close returned: ${log.join(' -> ')}',
        );
        expect(second.constructed, isFalse);
        expect(h.model.generated, 0);
        await _reopenAfterDrain(h, before);
      },
    );
  });

  test('backup after a stopped cold main waits for the same complete character read', () async {
    final h = await _open();
    await h.reopen();
    final work = await Directory.systemTemp.createTemp('dsh-t12-main-io-backup-');
    addTearDown(() => work.delete(recursive: true));
    final archive = File('${work.path}/after-stop.zip');
    final character = '${h.root.path}/characters/${h.characterId}';
    final log = _eventLog();
    // The preceding policy read does not load original.json or warm details.
    final card = _ReadGate('card', log, skipReads: 1);
    final original = _ReadGate('original', log);
    final captureStates = <Map<String, bool>>[];
    card.onCopy = () {
      final state = {'card': card.finished.isCompleted, 'original': original.finished.isCompleted};
      captureStates.add(state);
      log.add('backup:actual-card-copy-started:$state');
    };
    await _withGates(
      h,
      {'$character/card.json': card, '$character/original.json': original},
      drain: () => _drainCharacter(card, original),
      body: () async {
        final events = T24Events(h.engine.send(h.chatId, 'stop before backup admission'));
        await card.entered.future.timeout(_deadline);
        h.engine.stop(h.chatId);
        await _cancelled(events, log);
        expect(card.finished.isCompleted, isFalse);
        expect(h.model.generated, 0);
        // After the turn's terminal event, backup is accepted and waits for its
        // previously admitted IO. It is not supposed to fail with backup_busy.
        final backup = _DrainReceipt<TavernBackupInfo>(h.engine.backup(archive.path), 'backup', [card, original], log);
        if (_oldProductProbe) await backup.checked.timeout(_deadline);

        card.release();
        await original.entered.future.timeout(_deadline);
        expect(card.successfulReads, 1);
        expect(original.finished.isCompleted, isFalse);
        expect(backup.returned, isFalse, reason: log.join(' -> '));
        original.release();
        final info = await backup.checked.timeout(_deadline);
        expect(original.successfulReads, 1);
        expect(captureStates, [
          {'card': true, 'original': true},
        ], reason: 'Actual capture, not only ZIP completion, must follow the owned read. ${log.join(' -> ')}');
        expect(info.fileCount, greaterThan(0));
        expect(await archive.exists(), isTrue);
        expect(await archive.length(), greaterThan(0));
        expect(h.model.generated, 0);
        // Capture/compression finished and its admission barrier is released.
        expect((await h.engine.character(h.characterId))!.id, h.characterId);
      },
    );
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

List<String> _eventLog() {
  final log = <String>[];
  addTearDown(() {
    printOnFailure('T12-main-io complete event evidence: ${log.join(' -> ')}');
  });
  return log;
}

Future<void> _cancelled(T24Events events, List<String> log) async {
  await events.done.future.timeout(_deadline);
  log.add('turn:terminal-cancelled-and-stream-done');
  expect(events.values.whereType<TavernTurnStarted>(), isEmpty);
  expect(events.values.whereType<TavernTurnDone>(), isEmpty);
  final failed = events.values.whereType<TavernTurnFailed>().single;
  expect(failed.kind, TavernFailure.cancelled);
  expect(failed.partial, isNull);
}

// Keep the original failing future available to its later await, while handling
// its error immediately if a postcondition fails before the test releases IO.
Future<T> _handled<T>(Future<T> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  return future;
}

class _DrainReceipt<T> {
  _DrainReceipt(Future<T> operation, String name, List<_ReadGate> gates, List<String> log) {
    checked = _handled(_observe(operation, name, gates, log));
  }

  late final Future<T> checked;
  var returned = false;

  Future<T> _observe(Future<T> operation, String name, List<_ReadGate> gates, List<String> log) async {
    final result = await operation;
    returned = true;
    final completedReads = {for (final gate in gates) gate.name: gate.finished.isCompleted};
    log.add('$name:actually-returned:$completedReads');
    expect(completedReads, {
      for (final gate in gates) gate.name: true,
    }, reason: '$name returned while an admitted real read was still pending. ${log.join(' -> ')}');
    return result;
  }
}

Future<void> _expectReserved(Directory root, List<String> log) async {
  late final TavernEngine unexpected;
  try {
    unexpected = await TavernEngine.openDirectory(root);
  } on StateError {
    log.add('root:reopen-rejected');
    return;
  }
  // A failing old-product run must not leak the unexpectedly acquired owner.
  await unexpected.close();
  fail('The root was reopened before admitted main IO drained. ${log.join(' -> ')}');
}

Future<void> _reopenAfterDrain(T24Harness h, List<String> before) async {
  final reopened = await TavernEngine.openDirectory(h.root);
  try {
    expect((await reopened.path(h.chatId)).map((message) => message.nodeId), before);
  } finally {
    await reopened.close();
  }
}

Future<void> _withGates(
  T24Harness h,
  Map<String, _ReadGate> paths, {
  required Future<void> Function() drain,
  required Future<void> Function() body,
}) async {
  final parent = Zone.current;
  final gates = {for (final entry in paths.entries) File(entry.key).absolute.uri: entry.value};
  // Backup canonicalizes its source directory; include existing-file aliases
  // as well. Resolving a file path does not populate either engine cache.
  for (final entry in paths.entries) {
    final canonical = await File(entry.key).resolveSymbolicLinks();
    gates[File(canonical).absolute.uri] = entry.value;
  }
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        final gate = gates[parent.run(() => real.absolute.uri)];
        if (gate == null) return real;
        gate.constructed = true;
        return _GatedFile(real, gate);
      },
    );
  } finally {
    final closing = h.engine.close();
    for (final gate in gates.values) {
      gate.release();
    }
    // Old close may already have returned. Explicitly drain the genuine File
    // chain before the harness can delete its root, including negative runs.
    try {
      await drain();
    } finally {
      await closing;
    }
  }
}

Future<void> _drainCharacter(_ReadGate card, _ReadGate original) async {
  if (card.entered.isCompleted) {
    await card.finished.future;
    await original.finished.future;
  }
}

Future<void> _drainBooks(_ReadGate first, _ReadGate second) async {
  if (first.entered.isCompleted) await first.finished.future;
  // Cleanup only: after the first real read, the abandoned old loop has only
  // synchronous parsing/microtasks before constructing the second File. Drain
  // those microtasks, then own its real pending exists/read if it was admitted.
  // This event turn is never used as a success/negative-control oracle.
  await Future<void>(() {});
  if (second.constructed) await second.finished.future;
}

class _ReadGate {
  _ReadGate(this.name, this.log, {int skipReads = 0}) : _skipReads = skipReads;
  final String name;
  final List<String> log;
  int _skipReads;
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  var constructed = false;
  var reads = 0;
  var successfulReads = 0;
  void Function()? onCopy;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  Future<T> read<T>(Future<T> Function() action) async {
    if (_skipReads > 0) {
      _skipReads--;
      return action();
    }
    reads++;
    log.add('$name:read-entered');
    if (!entered.isCompleted) entered.complete();
    try {
      await _released.future;
      final result = await action();
      successfulReads++;
      log.add('$name:real-read-returned');
      return result;
    } finally {
      if (!finished.isCompleted) finished.complete();
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
  Future<File> copy(String path) {
    gate.onCopy?.call();
    return real.copy(path);
  }

  @override
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
