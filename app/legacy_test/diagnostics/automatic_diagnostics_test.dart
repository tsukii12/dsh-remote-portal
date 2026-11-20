import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/diagnostics/automatic_diagnostics.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticsSnapshot sample({
  int at = 100,
  String source = 'flutter',
  String errorType = 'StateError',
  String version = '1',
}) => DiagnosticsSnapshot(
  at: DateTime(2026, 11, 14),
  status: const RuntimeStatus(phase: RuntimePhase.running),
  settings: const AppSettings(),
  native: NativeDiagnostics(
    app: {'versionName': version},
    evidence: {
      'appErrors': [
        {'at': at, 'source': source, 'errorType': errorType},
      ],
      'voiceStages': <Object?>[],
      'processExits': <Object?>[],
    },
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default is disabled, and only failure observations trigger', () {
    expect(const AppSettings().automaticDiagnostics, isFalse);
    expect(
      diagnosticFailureWatermarks({
        'appErrors': [
          {'at': 1, 'source': 'session'},
        ],
        'voiceStages': [
          {'at': 2, 'stage': 'cancelled'},
          {'at': 3, 'stage': 'recording'},
        ],
        'processExits': [
          {'at': 4, 'reason': 10},
        ],
      }),
      isEmpty,
    );
    expect(
      diagnosticFailureWatermarks({
        'appErrors': [
          {'at': 10, 'source': 'platform'},
        ],
        'voiceStages': [
          {'at': 12, 'stage': 'failed'},
          {'at': 11, 'stage': 'error'},
        ],
        'processExits': [
          {'at': 13, 'reason': 6},
        ],
      }),
      {'appErrors': 10, 'voiceStages': 12, 'processExits': 13},
    );
  });

  test('persists before sending, restores report, deduplicates across restart', () async {
    Map<String, Object?> saved = {};
    var sends = 0;
    AutomaticDiagnostics make() => AutomaticDiagnostics(
      collect: () async => sample(),
      load: () async => saved,
      store: (value) async {
        saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
      },
    );
    Future<void> send(
      String prompt,
      bool Function() current,
      Future<void> Function(String, Future<void> Function()) created,
    ) async {
      expect((saved['through'] as Map)['appErrors'], 100);
      expect(current(), isTrue);
      expect(prompt, contains('StateError'));
      sends++;
      await created('report', () async {});
    }

    final first = make()..configure(Object(), send);
    await first.check();
    expect(first.phase, AutomaticDiagnosticsPhase.complete);
    expect(first.reportSessionId, 'report');
    await first.check();
    expect(sends, 1);
    first.dispose();
    final second = make();
    await second.ready;
    expect(second.reportSessionId, 'report', reason: 'visible even before enabling again');
    second.configure(Object(), send);
    await second.check();
    expect(sends, 1);
    second.dispose();
  });

  test('new timestamps of the same failure merge; different failure/version can send', () async {
    Map<String, Object?> saved = {};
    var current = sample();
    var now = DateTime(2026, 11, 14);
    var sends = 0;
    AutomaticDiagnostics make() =>
        AutomaticDiagnostics(
          clock: () => now,
          collect: () async => current,
          load: () async => saved,
          store: (value) async {
            saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    var automatic = make();
    await automatic.check();
    current = sample(at: 101);
    await automatic.check();
    expect(sends, 1, reason: 'same signature, later timestamp');
    automatic.dispose();
    automatic = make();
    current = sample(at: 102);
    await automatic.check();
    expect(sends, 1, reason: 'signature survives restart');
    current = sample(at: 103, errorType: 'TypeError');
    await automatic.check();
    expect(sends, 2);
    current = sample(at: 104, version: '2');
    await automatic.check();
    expect(sends, 3, reason: 'new app version');
    now = now.add(const Duration(hours: 25));
    current = sample(at: 105, version: '2');
    await automatic.check();
    expect(sends, 4, reason: 'a new event after the 24-hour merge window');
    expect((saved['fingerprints'] as Map).length, lessThanOrEqualTo(32));
    automatic.dispose();
  });

  test('analysis failure is visible, consumed once, and not entered into the error chain', () async {
    Map<String, Object?> saved = {};
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          collect: () async => sample(),
          load: () async => saved,
          store: (value) async {
            saved = value;
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
          throw StateError('synthetic analysis failure');
        });
    await automatic.check();
    expect(automatic.phase, AutomaticDiagnosticsPhase.failed);
    expect(automatic.failureCode, 'analysis_failed');
    await automatic.check();
    expect(sends, 1);
    automatic.dispose();
  });

  test('disable/host switch while collecting or persisting prevents the send', () async {
    for (final boundary in ['collect', 'store']) {
      final entered = Completer<void>();
      final resume = Completer<void>();
      var sends = 0;
      final automatic =
          AutomaticDiagnostics(
            load: () async => {},
            collect: () async {
              if (boundary == 'collect') {
                entered.complete();
                await resume.future;
              }
              return sample();
            },
            store: (_) async {
              if (boundary == 'store') {
                entered.complete();
                await resume.future;
              }
            },
          )..configure(Object(), (_, _, _) async {
            sends++;
          });
      final work = automatic.check();
      await entered.future;
      automatic.configure(null, null);
      resume.complete();
      await work;
      expect(sends, 0, reason: boundary);
      expect(automatic.phase, AutomaticDiagnosticsPhase.cancelled);
      automatic.dispose();
    }
  });

  test('revocation cancels only its captured analysis and never starts the replacement', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    var cancels = 0;
    var replacements = 0;
    final automatic = AutomaticDiagnostics(load: () async => {}, collect: () async => sample(), store: (_) async {})
      ..configure(Object(), (_, current, created) async {
        await created('local-report', () async {
          cancels++;
        });
        entered.complete();
        await resume.future;
        expect(current(), isFalse);
      });
    final work = automatic.check();
    await entered.future;
    automatic.configure(Object(), (_, _, _) async {
      replacements++;
    });
    resume.complete();
    await work;
    expect(cancels, 1);
    expect(replacements, 0);
    automatic.dispose();
  });

  test('persisted storage failure stays gated across restart until explicit recovery', () async {
    Map<String, Object?> saved = {
      'through': {'appErrors': 100},
      'fingerprints': <String, int>{},
      'phase': 'failed',
      'failureCode': 'store_failed',
    };
    var current = sample(at: 200);
    var collects = 0;
    var sends = 0;
    AutomaticDiagnostics make() =>
        AutomaticDiagnostics(
          collect: () async {
            collects++;
            return current;
          },
          load: () async => saved,
          store: (value) async {
            saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    final first = make();
    await first.ready;
    await first.check();
    expect(first.failureCode, 'store_failed');
    expect(collects, 0);
    expect(sends, 0);
    first.dispose();
    final restarted = make();
    await restarted.ready;
    await restarted.check();
    expect(collects, 0, reason: 'a readable checkpoint is not storage recovery consent');
    await restarted.recoverStorage(isCurrent: () => true);
    expect(restarted.failureCode, isNull);
    expect(sends, 0, reason: 'recovery baselines the retained failure without sending');
    await restarted.check();
    expect(sends, 0);
    current = sample(at: 201, errorType: 'TypeError');
    await restarted.check();
    expect(sends, 1);
    restarted.dispose();
  });

  test('explicit storage recovery skips retained failures and sends only a future new failure', () async {
    var fail = true;
    var current = sample();
    Map<String, Object?> saved = {};
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          collect: () async => current,
          load: () async => saved,
          store: (value) async {
            if (fail) throw StateError('storage unavailable');
            saved = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    await automatic.check();
    expect(automatic.failureCode, 'store_failed');
    fail = false;
    saved = {
      'through': {'appErrors': 50},
      'fingerprints': <String, int>{},
    };
    current = sample(at: 80);
    await automatic.recoverStorage(isCurrent: () => true);
    expect((saved['through'] as Map)['appErrors'], 100, reason: 'recovery must not lower consumed memory watermarks');
    expect(automatic.failureCode, isNull);
    expect(sends, 0, reason: 'recovery is strictly local');
    await automatic.check();
    current = sample(at: 101);
    await automatic.check();
    expect(sends, 0, reason: 'retained signature is baselined, including a later repeat');
    current = sample(at: 102, errorType: 'TypeError');
    await automatic.check();
    expect(sends, 1);
    automatic.dispose();
  });

  test('corrupt checkpoint can be explicitly rebuilt without replaying retained failures', () async {
    var corrupt = true;
    var current = sample();
    Map<String, Object?> saved = {};
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          collect: () async => current,
          load: () async {
            if (corrupt) throw const FormatException('synthetic invalid JSON');
            return saved;
          },
          store: (value) async {
            saved = value;
            corrupt = false;
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    await automatic.ready;
    expect(automatic.failureCode, 'store_failed');
    await automatic.recoverStorage(isCurrent: () => true);
    expect((saved['through'] as Map)['appErrors'], 100);
    expect((saved['fingerprints'] as Map).length, 1);
    expect(sends, 0);
    await automatic.check();
    expect(sends, 0);
    current = sample(at: 101, errorType: 'TypeError');
    await automatic.check();
    expect(sends, 1);
    automatic.dispose();
  });

  test('revocation during recovery collection or persistence cannot unlock analysis', () async {
    for (final boundary in ['collect', 'store']) {
      final entered = Completer<void>();
      final resume = Completer<void>();
      var recovering = false;
      var allowed = true;
      var sends = 0;
      final automatic =
          AutomaticDiagnostics(
            load: () async => throw const FormatException('unreadable checkpoint'),
            collect: () async {
              if (recovering && boundary == 'collect') {
                entered.complete();
                await resume.future;
              }
              return sample();
            },
            store: (_) async {
              if (recovering && boundary == 'store') {
                entered.complete();
                await resume.future;
              }
            },
          )..configure(Object(), (_, _, _) async {
            sends++;
          });
      await automatic.ready;
      recovering = true;
      final work = automatic.recoverStorage(isCurrent: () => allowed);
      await entered.future;
      allowed = false;
      automatic.configure(null, null);
      resume.complete();
      await work;
      expect(automatic.failureCode, 'store_failed', reason: boundary);
      automatic.configure(Object(), (_, _, _) async {
        sends++;
      });
      await automatic.check();
      expect(sends, 0, reason: 'revoked recovery never clears the storage gate');
      automatic.dispose();
    }
  });

  test('recovery cannot unlock without a current evidence baseline', () async {
    var writes = 0;
    final automatic = AutomaticDiagnostics(
      load: () async => throw const FormatException('unreadable checkpoint'),
      collect: () async => DiagnosticsSnapshot(
        at: DateTime.now(),
        status: const RuntimeStatus(phase: RuntimePhase.running),
        settings: const AppSettings(),
      ),
      store: (_) async {
        writes++;
      },
    );
    await automatic.ready;
    await automatic.recoverStorage(isCurrent: () => true);
    expect(automatic.failureCode, 'store_failed');
    expect(writes, 0);
    automatic.dispose();
  });

  test('a failed explicit recovery write stays failed and never retries in polling', () async {
    var writes = 0;
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          load: () async => throw const FormatException('unreadable checkpoint'),
          collect: () async => sample(),
          store: (_) async {
            writes++;
            throw StateError('still unavailable');
          },
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    await automatic.ready;
    await automatic.recoverStorage(isCurrent: () => true);
    expect(automatic.failureCode, 'store_failed');
    expect(writes, 1);
    await automatic.check();
    await automatic.check();
    expect(writes, 1);
    expect(sends, 0);
    automatic.dispose();
  });

  test('failed persistence blocks model submission', () async {
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          load: () async => {},
          collect: () async => sample(),
          store: (_) async => throw StateError('storage unavailable'),
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    await automatic.check();
    await automatic.check();
    expect(sends, 0);
    expect(automatic.failureCode, 'store_failed');
    automatic.dispose();
  });

  test('sender rejects missing or substituted no-tools preset without fallback', () async {
    for (final returned in [null, 'standard']) {
      final client = AnalysisClient()..returnedPreset = returned;
      await expectLater(sendDiagnosticAnalysis(client, 'facts', () => true, (_, _) async {}), throwsStateError);
      expect(client.calls, ['create:dsh-go-diagnostics']);
      await client.close();
    }
  });

  test('sender submits a real prompt to the independent no-tools session', () async {
    final client = AnalysisClient();
    await sendDiagnosticAnalysis(client, 'facts', () => true, (id, _) async {
      expect(id, 'analysis');
    });
    expect(client.calls, ['create:dsh-go-diagnostics', 'projections', 'rename', 'watch', 'prompt:facts']);
    expect(client.cancels, 0);
    await client.close();
  });

  test('sender refuses a substituted projection without sending facts', () async {
    final client = AnalysisClient()..projectionPreset = 'standard';
    await expectLater(sendDiagnosticAnalysis(client, 'facts', () => true, (_, _) async {}), throwsStateError);
    expect(client.calls, ['create:dsh-go-diagnostics', 'projections']);
    await client.close();
  });

  test('late prompt acceptance after timeout and revocation is cancelled once', () async {
    final client = AnalysisClient()..promptGate = Completer<void>();
    addTearDown(() async {
      if (!client.promptGate!.isCompleted) client.promptGate!.complete();
      await client.close();
    });
    final prompted = Completer<void>();
    client.onPrompt = () => prompted.complete();
    var allowed = true;
    late Future<void> Function() cancel;
    // This exercises RPC timing, not a widget. Use a short real deadline so
    // preparation, cancellation cleanup and late acceptance share one clock.
    final work = sendDiagnosticAnalysis(client, 'facts', () => allowed, (_, stop) async {
      cancel = stop;
    }, rpcWait: const Duration(milliseconds: 25));
    final failed = expectLater(work, throwsA(isA<TimeoutException>()));
    await prompted.future.timeout(const Duration(seconds: 5));
    allowed = false;
    final stopping = expectLater(cancel(), throwsA(isA<TimeoutException>()));
    await Future.wait([failed, stopping]).timeout(const Duration(seconds: 5));
    expect(client.cancels, 0, reason: 'do not cancel an idle session before the prompt is queued');
    client.promptGate!.complete();
    await pumpEventQueue();
    expect(client.cancels, 1, reason: 'the original RPC is retained beyond its timeout');
    expect(client.calls.where((call) => call.startsWith('prompt:')).length, 1);
  });

  test('cancel waits for an in-flight prompt acknowledgement, then stops once', () async {
    final client = AnalysisClient()..promptGate = Completer<void>();
    final prompted = Completer<void>();
    client.onPrompt = () => prompted.complete();
    var allowed = true;
    late Future<void> Function() cancel;
    final work = sendDiagnosticAnalysis(client, 'facts', () => allowed, (_, stop) async {
      cancel = stop;
    });
    final failure = expectLater(work, throwsStateError);
    await prompted.future;
    allowed = false;
    final stopping = cancel();
    expect(client.cancels, 0);
    client.promptGate!.complete();
    await stopping;
    await failure;
    expect(client.cancels, 1);
    await client.close();
  });
}

class AnalysisClient extends DshClient {
  AnalysisClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final calls = <String>[];
  String? returnedPreset = 'dsh-go-diagnostics';
  String? projectionPreset = 'dsh-go-diagnostics';
  final events = StreamController<DshEvent>.broadcast();
  Completer<void>? promptGate;
  void Function()? onPrompt;
  int cancels = 0;

  @override
  Future<SessionCreated> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
    String? sessionId,
  }) async {
    calls.add('create:$agentPreset');
    return SessionCreated('analysis', returnedPreset);
  }

  @override
  Future<SessionProjections?> projections(String sessionId) async {
    calls.add('projections');
    return SessionProjections(0, {'agentPreset': projectionPreset});
  }

  @override
  Future<String> renameSession(String sessionId, String title) async {
    calls.add('rename');
    return title;
  }

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    calls.add('watch');
    scheduleMicrotask(
      () => events.add(
        SessionSnapshotEvent.fromJson('analysis', {
          'header': {'id': 'analysis'},
          'cursor': -1,
          'records': <Object?>[],
        }),
      ),
    );
    return events.stream;
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    expect(sessionId, 'analysis');
    calls.add('prompt:$text');
    onPrompt?.call();
    await promptGate?.future;
    if (promptGate == null) {
      events.add(TurnEndedEvent(1, DateTime.now(), const {}, turn: 1, reason: const TurnEndReason('completed')));
    }
    return 'request';
  }

  @override
  Future<void> cancel(String sessionId) async {
    expect(sessionId, 'analysis');
    cancels++;
  }

  @override
  Future<void> close() async {
    await events.close();
    await super.close();
  }
}
