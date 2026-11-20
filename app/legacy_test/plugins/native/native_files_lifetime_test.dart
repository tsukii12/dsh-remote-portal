import 'dart:async';

import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_file_platform.dart';
import 'package:dsh_app/plugins/native/native_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _second = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _third = 'cccccccccccccccccccccccccccccccc';
final _now = DateTime.utc(2026, 1, 1);

class _Transport implements NativeFileTransport {
  final statuses = <(String, String)>[];
  final uploads = <(String, List<int>)>[];

  @override
  Future<void> upload(String request, String stream, NativeSelectedFile file, Uint8List bytes) async {
    uploads.add((request, List.of(bytes)));
  }

  @override
  Future<DshGoInvokeResult> complete(String request, String stream, String status) async {
    statuses.add((request, status));
    return const DshGoInvokeResult();
  }
}

class _Run {
  _Run(NativeFileCoordinator runtime, String owner, {int maxFiles = 1}) {
    unawaited(
      runtime
          .execute(
            PickFileEffect(
              request: owner,
              action: 'selected',
              images: false,
              maxFiles: maxFiles,
              maxBytes: 8,
              maxTotalBytes: 16,
            ),
            pkg: 'files',
            stream: 'c1',
            userGesture: true,
            tappedAt: _now,
            now: () => _now,
            isCurrent: () => true,
          )
          .then(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object error) {
              failure = error;
              done = true;
            },
          ),
    );
  }
  bool done = false;
  Object? failure;
  DshGoInvokeResult? result;
}

void _channel(Future<Object?> Function(MethodCall) handler) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(MethodNativeFilePlatform.channel, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(MethodNativeFilePlatform.channel, null));
}

void main() {
  for (final partial in [false, true]) {
    testWidgets('read deadline releases a ${partial ? 'partial' : 'empty'} stalled read without its reply', (
      tester,
    ) async {
      final oldRead = Completer<Object?>(), newPicker = Completer<Object?>();
      final transport = _Transport(), gate = NativeFileGate();
      final cancels = <String>[];
      var reads = 0, holds = 0, releases = 0;
      _channel((call) async {
        final args = call.arguments as Map?;
        switch (call.method) {
          case 'capabilities':
            return {'files': true};
          case 'pick':
            if (args!['owner'] == _second) return newPicker.future;
            return [
              {'handle': 'selected-file', 'name': 'cloud.txt', 'bytes': null},
            ];
          case 'read':
            reads++;
            if (partial && reads == 1) return Uint8List.fromList([7]);
            return oldRead.future;
          case 'cancel':
            cancels.add(args!['owner'] as String);
            // Native cancellation acknowledges immediately, but its provider
            // is deliberately still busy. No artificial read reply unblocks us.
            return null;
          default:
            throw StateError(call.method);
        }
      });
      final runtime = NativeFileCoordinator(
        platform: MethodNativeFilePlatform(),
        transport: transport,
        gate: gate,
        holdSystemSelection: () {
          holds++;
          return () => releases++;
        },
      );
      final old = _Run(runtime, _first);
      await tester.pump();
      expect(reads, partial ? 2 : 1);
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      final doneAtDeadline = old.done;
      final statusesAtDeadline = List.of(transport.statuses);
      debugPrint(
        'F3_READ_DEADLINE partial=$partial done=$doneAtDeadline statuses=$statusesAtDeadline holds=$holds releases=$releases cancels=$cancels',
      );
      // Always unblock the fixture if the regression returns, to keep a red
      // test from retaining pending work into the following test.
      if (!doneAtDeadline) {
        oldRead.complete(null);
        await tester.pump();
      }
      expect(doneAtDeadline, true);
      expect(statusesAtDeadline, [(_first, 'error')]);
      expect(old.failure, isA<NativeFileException>());
      expect(transport.uploads, isEmpty);
      expect(cancels, [_first]);
      expect((holds, releases), (1, 1));
      expect(runtime.package, isNull);
      expect(gate.claim(), true);
      gate.release();

      final fresh = _Run(runtime, _second);
      await tester.pump();
      expect(fresh.done, false);
      expect((holds, releases), (2, 1));
      if (partial) {
        oldRead.complete(Uint8List.fromList([9]));
      } else {
        oldRead.completeError(PlatformException(code: 'cancelled'));
      }
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(cancels, [_first], reason: 'old data/error/timers must not cancel the new owner');
      expect(transport.statuses, [(_first, 'error')]);
      expect(transport.uploads, isEmpty);
      expect(reads, partial ? 2 : 1);
      newPicker.complete([]);
      await tester.pump();
      expect(fresh.done, true);
      expect(fresh.failure, isNull);
      expect(transport.statuses, [(_first, 'error'), (_second, 'cancelled')]);
      expect(cancels, [_first, _second]);
      expect((holds, releases), (2, 2));
    });
  }

  testWidgets('external cancellation terminates a blocked reader once without waiting for its source', (tester) async {
    final blocked = Completer<Object?>();
    final transport = _Transport(), gate = NativeFileGate();
    final cancels = <String>[];
    var released = 0;
    _channel((call) async {
      switch (call.method) {
        case 'capabilities':
          return {'files': true};
        case 'pick':
          return [
            {'handle': 'read', 'name': 'slow', 'bytes': null},
          ];
        case 'read':
          return blocked.future;
        case 'cancel':
          cancels.add((call.arguments as Map)['owner'] as String);
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final runtime = NativeFileCoordinator(
      platform: MethodNativeFilePlatform(),
      transport: transport,
      gate: gate,
      holdSystemSelection: () =>
          () => released++,
    );
    final run = _Run(runtime, _first);
    await tester.pump();
    unawaited(runtime.cancel());
    unawaited(runtime.cancel());
    await tester.pump();
    final cancelledWithoutReply = run.done;
    if (!cancelledWithoutReply) {
      blocked.complete(null);
      await tester.pump();
    }
    expect(cancelledWithoutReply, true);
    expect(run.failure, isNull);
    expect(transport.statuses, [(_first, 'cancelled')]);
    expect(cancels, [_first]);
    expect(released, 1);
    expect(gate.claim(), true);
    gate.release();
    if (!blocked.isCompleted) blocked.complete(Uint8List.fromList([1]));
    await tester.pump(const Duration(seconds: 11));
    expect(transport.uploads, isEmpty);
    expect(transport.statuses, [(_first, 'cancelled')]);
    expect(cancels, [_first]);
  });

  testWidgets('real byte progress resets the idle deadline across a longer transfer', (tester) async {
    final chunks = List.generate(3, (_) => Completer<Object?>());
    final transport = _Transport(), gate = NativeFileGate();
    var reads = 0, cancels = 0;
    _channel((call) async {
      switch (call.method) {
        case 'capabilities':
          return {'files': true};
        case 'pick':
          return [
            {'handle': 'read', 'name': 'slow', 'bytes': null},
          ];
        case 'read':
          final index = reads++;
          final value = await chunks[index].future;
          return value;
        case 'cancel':
          cancels++;
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final runtime = NativeFileCoordinator(platform: MethodNativeFilePlatform(), transport: transport, gate: gate);
    final run = _Run(runtime, _first);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 9));
      expect(run.done, false);
      expect(cancels, 0);
      expect(reads, i + 1);
      chunks[i].complete(i == 2 ? null : Uint8List.fromList([i + 1]));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 1));
    debugPrint('F3_PROGRESS end reads=$reads cancels=$cancels done=${run.done} statuses=${transport.statuses}');
    expect(run.done, true);
    expect(run.failure, isNull);
    expect(transport.uploads.map((entry) => entry.$1), [_first]);
    expect(transport.uploads.single.$2, [1, 2]);
    expect(transport.statuses, [(_first, 'selected')]);
    expect(cancels, 1);
    await tester.pump(const Duration(seconds: 11));
    expect(cancels, 1, reason: 'success must clear the last idle timer');
  });

  testWidgets('a later file timeout revokes a batch with an already uploaded file', (tester) async {
    final blocked = Completer<Object?>();
    final transport = _Transport(), gate = NativeFileGate();
    var firstReads = 0, cancels = 0, releases = 0;
    _channel((call) async {
      switch (call.method) {
        case 'capabilities':
          return {'files': true};
        case 'pick':
          return [
            {'handle': 'first', 'name': 'first', 'bytes': 2},
            {'handle': 'second', 'name': 'second', 'bytes': null},
          ];
        case 'read':
          if ((call.arguments as Map)['handle'] == 'first') {
            return firstReads++ == 0 ? Uint8List.fromList([1, 2]) : null;
          }
          return blocked.future;
        case 'cancel':
          cancels++;
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final runtime = NativeFileCoordinator(
      platform: MethodNativeFilePlatform(),
      transport: transport,
      gate: gate,
      holdSystemSelection: () =>
          () => releases++,
    );
    final run = _Run(runtime, _first, maxFiles: 2);
    await tester.pump();
    expect(transport.uploads, hasLength(1));
    expect(transport.uploads.single.$2, [1, 2]);
    expect(transport.statuses, isEmpty);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(run.done, true);
    expect(run.failure, isA<NativeFileException>());
    expect(transport.statuses, [(_first, 'error')]);
    expect(cancels, 1);
    expect(releases, 1);
    expect(gate.claim(), true);
    gate.release();
    blocked.complete(Uint8List.fromList([9]));
    await tester.pump();
    expect(transport.uploads, hasLength(1));
    expect(transport.statuses, [(_first, 'error')]);
  });

  for (final cancelFirst in [true, false]) {
    testWidgets('deadline and external cancellation settle once, cancelFirst=$cancelFirst', (tester) async {
      final blocked = Completer<Object?>();
      final transport = _Transport(), gate = NativeFileGate();
      final cancels = <String>[];
      var releases = 0;
      _channel((call) async {
        switch (call.method) {
          case 'capabilities':
            return {'files': true};
          case 'pick':
            return [
              {'handle': 'read', 'name': 'slow', 'bytes': null},
            ];
          case 'read':
            return blocked.future;
          case 'cancel':
            cancels.add((call.arguments as Map)['owner'] as String);
            return null;
          default:
            throw StateError(call.method);
        }
      });
      final runtime = NativeFileCoordinator(
        platform: MethodNativeFilePlatform(),
        transport: transport,
        gate: gate,
        holdSystemSelection: () =>
            () => releases++,
      );
      void scheduleCancel() => Timer(const Duration(seconds: 10), () => unawaited(runtime.cancel()));
      if (cancelFirst) scheduleCancel();
      final run = _Run(runtime, _first);
      await tester.pump();
      if (!cancelFirst) scheduleCancel();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(run.done, true);
      expect(transport.statuses, hasLength(1));
      expect(transport.statuses.single.$1, _first);
      expect(transport.statuses.single.$2, isIn(['error', 'cancelled']));
      expect(transport.uploads, isEmpty);
      expect(cancels, [_first]);
      expect(releases, 1);
      expect(gate.claim(), true);
      gate.release();
      blocked.completeError(PlatformException(code: 'cancelled'));
      await tester.pump(const Duration(seconds: 11));
      expect(transport.statuses, hasLength(1));
      expect(cancels, [_first]);
      expect(releases, 1);
    });
  }

  testWidgets('a timed-out native reader retains its native busy guard while the App gate recovers', (tester) async {
    final blocked = Completer<Object?>();
    final transport = _Transport(), gate = NativeFileGate();
    final owners = <String>[];
    var nativeBusy = false, reads = 0, cancelled = false;
    _channel((call) async {
      final owner = (call.arguments as Map?)?['owner'] as String?;
      switch (call.method) {
        case 'capabilities':
          return {'files': true};
        case 'pick':
          owners.add(owner!);
          if (nativeBusy) throw PlatformException(code: 'busy');
          if (owner == _third) return [];
          return [
            {'handle': 'read', 'name': 'slow', 'bytes': null},
          ];
        case 'read':
          reads++;
          nativeBusy = true;
          try {
            return await blocked.future;
          } finally {
            nativeBusy = false;
          }
        case 'cancel':
          if (owner == _first) cancelled = true;
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final runtime = NativeFileCoordinator(platform: MethodNativeFilePlatform(), transport: transport, gate: gate);
    final old = _Run(runtime, _first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    final doneAtDeadline = old.done;
    if (!doneAtDeadline) {
      blocked.complete(null);
      await tester.pump();
    }
    expect(doneAtDeadline, true);
    expect(cancelled, true);
    expect(nativeBusy, true);
    final busy = _Run(runtime, _second);
    await tester.pump();
    expect(busy.done, true);
    expect(busy.failure, isA<NativeFileException>().having((e) => e.problem, 'native busy', NativeFileProblem.busy));
    expect(reads, 1);
    expect(owners, [_first, _second]);
    blocked.completeError(PlatformException(code: 'cancelled'));
    await tester.pump();
    final fresh = _Run(runtime, _third);
    await tester.pump();
    expect(fresh.done, true);
    expect(fresh.failure, isNull);
    expect(transport.uploads, isEmpty);
    expect(transport.statuses, [(_first, 'error'), (_second, 'error'), (_third, 'cancelled')]);
  });
}
