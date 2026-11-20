import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dsh_tavern/src/regex/regex_engine.dart';
import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:test/test.dart';

void main() {
  test('native recognition distinguishes plain fallback from incompatible literals', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    for (final text in ['plain', '/x/v', '/x/ii', '/a/b/']) {
      expect(isNativeRegexLiteral(text), isFalse);
      final result = await worker.hasMatch(text, text, dialect: RegexDialect.nativeKeyword);
      expect(result.status, RegexMatchStatus.skipped);
      expect(result.compilation.status, RegexCompileStatus.literalFallback);
    }
    expect(isNativeRegexLiteral('/(/'), isTrue);
    final invalid = await worker.hasMatch('/(/', '/(/', dialect: RegexDialect.nativeKeyword);
    expect(invalid.status, RegexMatchStatus.skipped);
    expect(invalid.compilation.status, RegexCompileStatus.incompatible);
    expect(invalid.code, 'incompatible-pattern');
    final v3 = await worker.compile('/x/v', dialect: RegexDialect.v3Keyword);
    expect(v3.status, RegexCompileStatus.incompatible);
    expect(v3.code, 'invalid-literal');
  });

  test('native sticky, lookbehind and named groups use actual runtime support', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    expect((await worker.hasMatch('/猫/y', '猫尾', dialect: RegexDialect.nativeKeyword)).status, RegexMatchStatus.matched);
    expect(
      (await worker.hasMatch('/猫/y', '前猫', dialect: RegexDialect.nativeKeyword)).status,
      RegexMatchStatus.notMatched,
    );
    expect(
      (await worker.hasMatch(r'/(?<=前)(?<pet>猫)/u', '前猫', dialect: RegexDialect.nativeKeyword)).status,
      RegexMatchStatus.matched,
    );
    expect(
      (await worker.hasMatch('CAT', 'cat', dialect: RegexDialect.v3Keyword, caseSensitive: false)).status,
      RegexMatchStatus.matched,
    );
    expect((await worker.hasMatch('CAT', 'cat', dialect: RegexDialect.v3Keyword)).status, RegexMatchStatus.notMatched);
  });

  test('script unknown flags keep ST whole-string fallback rather than deleting flags', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    for (final flag in ['y', 'v']) {
      final result = await worker.hasMatch('/x/$flag', 'literal /x/$flag');
      expect(result.status, RegexMatchStatus.matched);
      expect(result.compilation.status, RegexCompileStatus.compatible);
      expect(result.code, 'literal-fallback');
      expect((await worker.hasMatch('/x/$flag', 'x')).status, RegexMatchStatus.notMatched);
    }
  });

  test('only requested capture groups cross the worker boundary', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    final result = await worker.findCaptures(
      r'/(?<letter>a)(b)?/g',
      'a ab',
      references: ['1', 'n:letter', '9'],
      maxMatches: 5,
    );
    expect(result.skipped, isFalse);
    expect(result.matches, hasLength(2));
    final first = result.matches.first;
    expect((first.start, first.end, first.groupCount, first.hasNamedGroups), (0, 1, 2, true));
    expect(first.groups, {'1': 'a', 'n:letter': 'a', '9': null});
    expect(first.groups.containsKey('0'), isFalse);
    expect(first.groups.containsKey('2'), isFalse);
    expect(() => first.groups['1'] = 'mutated', throwsUnsupportedError);
  });

  test('UTF8 counters agree with the SDK encoder without rewriting surrogates', () {
    for (var unit = 0; unit <= 0xffff; unit++) {
      final text = String.fromCharCode(unit);
      expect(regexUtf8Length(text), utf8.encode(text).length, reason: 'code unit $unit');
    }
    for (final text in ['你😀', '\r\n', '\ud800x\udc00', '\ud83d\ude00', '\ud800\ud800\udc00']) {
      expect(regexUtf8Length(text), utf8.encode(text).length);
      expect(regexUtf8Length(text, stopAfter: 0), greaterThan(0));
    }
  });

  test('raw input and pattern boundaries count UTF8 bytes', () async {
    final worker = RegexWorker(limits: const RegexLimits(maxInputBytes: 8));
    addTearDown(worker.close);
    const exact = '你😀a';
    expect(regexUtf8Length(exact), 8);
    expect((await worker.hasMatch('你', exact, dialect: RegexDialect.v3Keyword)).status, RegexMatchStatus.matched);
    expect((await worker.hasMatch('你', '${exact}b', dialect: RegexDialect.v3Keyword)).code, 'input-limit');
    expect((await worker.compile(exact, dialect: RegexDialect.v3Keyword)).status, RegexCompileStatus.compatible);
    expect((await worker.compile('${exact}b', dialect: RegexDialect.v3Keyword)).code, 'pattern-limit');
  });

  test('capture input may exceed the external limit but not the output limit', () async {
    final worker = RegexWorker(limits: const RegexLimits(maxInputBytes: 4, maxOutputBytes: 8));
    addTearDown(worker.close);
    final exact = await worker.findCaptures('x', 'xxxxxxxx', references: [], maxMatches: 1);
    expect(exact.skipped, isFalse);
    expect(exact.matches, hasLength(1));
    final large = await worker.findCaptures('x', 'xxxxxxxxx', references: [], maxMatches: 1);
    expect(large.code, 'input-limit');
  });

  test('empty capture metadata itself consumes the bounded transfer budget', () async {
    final worker = RegexWorker(limits: const RegexLimits(maxCaptureBytes: 100));
    addTearDown(worker.close);
    final result = await worker.findCaptures('/(a)?/g', 'x', references: ['1'], maxMatches: 10);
    expect(result.code, 'capture-limit');
    expect(result.matches, isEmpty);
  });

  test('match count overflow drops one rule and leaves the worker reusable', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    expect((await worker.findCaptures('/x/g', 'xx', references: [], maxMatches: 2)).matches, hasLength(2));
    expect((await worker.findCaptures('/x/g', 'xxx', references: [], maxMatches: 2)).code, 'replacement-limit');
    expect((await worker.hasMatch('y', 'y')).status, RegexMatchStatus.matched);
    expect((await worker.findCaptures('/x/g', 'z', references: [], maxMatches: 0)).skipped, isFalse);
  });

  test('dynamic import checks do not run patterns or consume a worker', () async {
    var spawns = 0;
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        return _spawn(entry, replies, errors, exits);
      },
    );
    addTearDown(worker.close);
    for (final substitute in [1, 2]) {
      final script = RegexScript.fromJson({
        'findRegex': '{{incvar::n}}',
        'replaceString': '',
        'substituteRegex': substitute,
      });
      final result = await RegexEngine.checkScript(script, worker);
      expect(result.status, RegexCompileStatus.skipped);
      expect(result.code, 'runtime-check');
    }
    expect(spawns, 0);
    final malformed = RegexScript.fromJson({'findRegex': 1, 'replaceString': ''});
    expect((await RegexEngine.checkScript(malformed, worker)).code, 'invalid-script');
    expect(spawns, 0);
  });

  test('normal requests reuse one resident worker and close resolves future calls', () async {
    var spawns = 0;
    final exited = Completer<void>();
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        return _spawnWithExit(entry, replies, errors, exits, () => exited.complete());
      },
    );
    addTearDown(worker.close);
    expect((await worker.compile('x')).status, RegexCompileStatus.compatible);
    expect((await worker.hasMatch('x', 'no')).status, RegexMatchStatus.notMatched);
    expect((await worker.hasMatch('x', 'x')).status, RegexMatchStatus.matched);
    expect(spawns, 1);
    await worker.close();
    await exited.future.timeout(const Duration(seconds: 3));
    await worker.close();
    expect((await worker.compile('x')).code, 'worker-closed');
    expect(spawns, 1);
  });

  test('deadline interrupts a busy worker while owner heartbeat and recovery continue', () async {
    var spawns = 0;
    var oldExited = false;
    var replacementBeforeExit = false;
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        if (spawns == 1) {
          return _spawnWithExit(_busyAfterWarmup, replies, errors, exits, () => oldExited = true);
        }
        replacementBeforeExit |= !oldExited;
        return _spawn(entry, replies, errors, exits);
      },
    );
    addTearDown(worker.close);
    expect((await worker.compile('warm')).status, RegexCompileStatus.compatible);
    var beats = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) => beats++);
    addTearDown(heartbeat.cancel);
    final failed = await worker.hasMatch('busy', 'x');
    expect(failed.status, RegexMatchStatus.skipped);
    expect(failed.code, 'timeout');
    expect(beats, greaterThan(5));
    final next = await worker.hasMatch('x', 'x');
    expect(next.status, RegexMatchStatus.matched);
    expect(oldExited, isTrue);
    expect(replacementBeforeExit, isFalse);
    expect(spawns, 2);
  });

  test('queue capacity rejects excess waiters while accepted requests finish in order', () async {
    final gate = _Gate();
    final worker = RegexWorker(limits: const RegexLimits(maxPending: 2), spawner: gate.spawn);
    addTearDown(worker.close);
    final active = worker.hasMatch('a', 'a');
    await gate.started.future;
    final second = worker.compile('b');
    final third = worker.compile('c');
    final excess = await worker.compile('d');
    expect(excess.code, 'worker-busy');
    (await gate.commands.future).send({'release': true});
    expect((await active).status, RegexMatchStatus.matched);
    expect((await second).status, RegexCompileStatus.compatible);
    expect((await third).status, RegexCompileStatus.compatible);
    expect(gate.patterns, ['a', 'b', 'c']);
  });

  test('retiring worker remains unavailable until its actual exit notification is delivered', () async {
    var spawns = 0;
    SendPort? exitTarget;
    final heldExit = Completer<Object?>();
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        if (spawns != 1) {
          return _spawn(entry, replies, errors, exits);
        }
        exitTarget = exits;
        final observed = ReceivePort();
        observed.listen((Object? value) {
          heldExit.complete(value);
          observed.close();
        });
        return _spawn(_gatedWorker, replies, errors, observed.sendPort);
      },
    );
    addTearDown(() async {
      if (heldExit.isCompleted) {
        exitTarget?.send(await heldExit.future);
      }
      await worker.close();
    });
    expect((await worker.hasMatch('held', 'x')).code, 'timeout');
    final actualExit = await heldExit.future.timeout(const Duration(seconds: 3));
    for (var attempt = 0; attempt < 3; attempt++) {
      final unavailable = await worker.compile('still-retiring');
      expect(unavailable.status, RegexCompileStatus.skipped);
      expect(unavailable.code, 'timeout');
      expect(spawns, 1);
    }
    exitTarget!.send(actualExit);
    final recoveryClock = Stopwatch()..start();
    RegexMatchResult recovered;
    do {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      recovered = await worker.hasMatch('x', 'x');
    } while (recovered.status == RegexMatchStatus.skipped && recoveryClock.elapsed < const Duration(seconds: 3));
    expect(recovered.status, RegexMatchStatus.matched);
    expect(spawns, 2);
  });

  test('close completes the active and queued requests without waiting for their work', () async {
    final gate = _Gate();
    final worker = RegexWorker(spawner: gate.spawn);
    addTearDown(worker.close);
    final active = worker.hasMatch('a', 'a');
    await gate.started.future;
    final pending = worker.compile('b');
    await worker.close();
    expect((await active).code, 'worker-closed');
    expect((await pending).code, 'worker-closed');
    expect(gate.patterns, ['a']);
  });

  test('spawn failure and uncaught worker exit do not strand later requests', () async {
    var spawns = 0;
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        if (spawns == 1) {
          return Future<Isolate>.error(StateError('injected spawn failure'));
        }
        return _spawn(spawns == 2 ? _throwingWorker : entry, replies, errors, exits);
      },
    );
    addTearDown(worker.close);
    expect((await worker.compile('first')).code, 'worker-start-failed');
    final failed = await worker.hasMatch('second', 'x');
    expect(failed.status, RegexMatchStatus.skipped);
    expect(failed.code, anyOf('worker-error', 'worker-exited'));
    expect((await worker.hasMatch('x', 'no')).status, RegexMatchStatus.notMatched);
    expect(spawns, 3);
  });

  test('a worker that never becomes ready is killed before replacement starts', () async {
    var spawns = 0;
    var oldExited = false;
    var replacedEarly = false;
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        spawns++;
        if (spawns == 1) {
          return _spawnWithExit(_neverReady, replies, errors, exits, () => oldExited = true);
        }
        replacedEarly |= !oldExited;
        return _spawn(entry, replies, errors, exits);
      },
    );
    addTearDown(worker.close);
    expect((await worker.compile('first')).code, 'worker-start-timeout');
    expect((await worker.compile('next')).status, RegexCompileStatus.compatible);
    expect(replacedEarly, isFalse);
    expect(oldExited, isTrue);
    expect(spawns, 2);
  });

  test('close before a late spawn handle kills that handle and leaves no resident worker', () async {
    final held = Completer<Isolate>();
    final created = Completer<Isolate>();
    final exited = Completer<void>();
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) {
        unawaited(
          _spawnWithExit(_gatedWorker, replies, errors, exits, () => exited.complete()).then<void>(created.complete),
        );
        return held.future;
      },
    );
    final pending = worker.compile('late');
    final actual = await created.future;
    addTearDown(() async {
      if (!held.isCompleted) {
        held.complete(actual);
      }
      await worker.close();
    });
    final closing = worker.close();
    await Future<void>.delayed(Duration.zero);
    held.complete(actual);
    await closing;
    await exited.future.timeout(const Duration(seconds: 3));
    expect((await pending).code, 'worker-closed');
    expect((await worker.compile('after')).code, 'worker-closed');
  });

  test('replies with stale epochs or request ids cannot finish the active job', () async {
    final worker = RegexWorker(
      spawner: (entry, replies, errors, exits) => _spawn(_wrongThenRightWorker, replies, errors, exits),
    );
    addTearDown(worker.close);
    final result = await worker.hasMatch('x', 'no');
    expect(result.status, RegexMatchStatus.notMatched);
    expect(result.code, isNull);
  });
}

Future<Isolate> _spawn(void Function(SendPort) entry, SendPort replies, SendPort errors, SendPort exits) =>
    Isolate.spawn(entry, replies, onError: errors, onExit: exits, errorsAreFatal: true);

Future<Isolate> _spawnWithExit(
  void Function(SendPort) entry,
  SendPort replies,
  SendPort errors,
  SendPort exits,
  void Function() onExit,
) async {
  final observed = ReceivePort();
  observed.listen((message) {
    onExit();
    exits.send(message);
    observed.close();
  });
  try {
    return await _spawn(entry, replies, errors, observed.sendPort);
  } catch (_) {
    observed.close();
    rethrow;
  }
}

void _reply(SendPort replies, Map<String, Object?> command, {bool matched = true}) {
  replies.send({
    'epoch': command['epoch'],
    'id': command['id'],
    'status': 'compatible',
    if (command['operation'] == 'match') 'matched': matched,
  });
}

void _busyAfterWarmup(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  commands.listen((Object? value) {
    final command = value! as Map<String, Object?>;
    if (command['operation'] == 'compile') {
      _reply(replies, command);
      return;
    }
    // A finite synchronous workload checks kill/event-loop isolation without
    // embedding an attack pattern or relying on a specific regex JIT engine.
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 10)) {}
    _reply(replies, command);
  });
}

void _throwingWorker(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  commands.listen((_) => throw StateError('injected worker failure'));
}

void _neverReady(SendPort _) {
  ReceivePort().listen((_) {});
}

void _wrongThenRightWorker(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  commands.listen((Object? value) {
    final command = value! as Map<String, Object?>;
    replies.send({
      'epoch': (command['epoch']! as int) + 1,
      'id': command['id'],
      'status': 'compatible',
      'matched': true,
    });
    replies.send({
      'epoch': command['epoch'],
      'id': (command['id']! as int) + 1,
      'status': 'compatible',
      'matched': true,
    });
    _reply(replies, command, matched: false);
  });
}

final class _Gate {
  final commands = Completer<SendPort>();
  final started = Completer<void>();
  final patterns = <String>[];

  Future<Isolate> spawn(void Function(SendPort) _, SendPort replies, SendPort errors, SendPort exits) {
    final proxy = ReceivePort();
    proxy.listen((Object? value) {
      if (value is SendPort) {
        commands.complete(value);
      }
      if (value is List<Object?> && value.first == 'started') {
        patterns.add(value[1]! as String);
        if (!started.isCompleted) {
          started.complete();
        }
      } else {
        replies.send(value);
      }
    });
    return _spawnWithExit(_gatedWorker, proxy.sendPort, errors, exits, proxy.close);
  }
}

void _gatedWorker(SendPort replies) {
  final commands = ReceivePort();
  final held = <Map<String, Object?>>[];
  var released = false;
  replies.send(commands.sendPort);
  commands.listen((Object? value) {
    final command = value! as Map<String, Object?>;
    if (command['release'] == true) {
      released = true;
      for (final pending in held) {
        _reply(replies, pending);
      }
      held.clear();
      return;
    }
    replies.send(['started', command['pattern']]);
    if (released) {
      _reply(replies, command);
    } else {
      held.add(command);
    }
  });
}
