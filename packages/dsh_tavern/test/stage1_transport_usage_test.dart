import 'dart:async';
import 'dart:convert';
import 'dart:mirrors' as mirrors;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/llm/tool_calls.dart';
import 'package:dsh_tavern/src/llm/tool_usage.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/stage1_engine_harness.dart';
import 'support/t24_engine_harness.dart';

void main() {
  test('raw null usage is observed before the same payload first text even when the reader stops there', () async {
    final reports = <ModelUsageReport>[];
    final context = ModelRequestContext(cancellation: ModelCancellation(), onUsageReport: reports.add);
    final client = _Client(
      (_) async => _sse([
        {
          'usage': null,
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'first'},
            },
          ],
        },
      ]),
    );
    final first = await TavernModelClient(
      clientFactory: () => client,
    ).generate(config: _config(), body: const {}, cancellation: context).first;
    expect(first, isA<ModelText>());
    expect(reports, hasLength(1));
    expect(reports.single.rawPresent, isTrue);
    expect(reports.single.raw, isNull);
    expect(reports.single.fields.values.map((field) => stage1Map(field)['state']), everyElement('invalid'));
    expect(client.sent, 1);
    expect(client.closed, isTrue);
  });

  test('Map then null followed by accepted-stream failure retains the later invalid observation', () async {
    var ledger = emptyToolUsageLedger();
    final reports = <ModelUsageReport>[];
    final context = ModelRequestContext(
      cancellation: ModelCancellation(),
      onUsageReport: (report) {
        reports.add(report);
        ledger = recordToolUsageObservation(ledger, report: report).ledger;
      },
    );
    Stream<List<int>> source() async* {
      yield _frame({
        'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'prompt_cache_hit_tokens': 1},
        'choices': [],
      });
      yield _frame({'usage': null, 'choices': []});
      throw http.ClientException('accepted stream interrupted');
    }

    final client = _Client((_) async => http.StreamedResponse(source(), 200));
    final deltas = <ModelDelta>[];
    await expectLater(
      TavernModelClient(
        clientFactory: () => client,
      ).generate(config: _config(), body: const {}, cancellation: context).forEach(deltas.add),
      throwsA(isA<TavernModelException>()),
    );
    expect(client.sent, 1);
    expect(reports.map((report) => report.observationIndex), [0, 1]);
    expect(deltas.whereType<ModelUsage>(), hasLength(1));
    expect(deltas.whereType<ModelFinished>(), isEmpty);
    expect(stage1Rows(ledger['observations']), hasLength(2));
    expect(ledger['selectedObservationSequence'], 1);
    final summary = summarizeToolUsage([(requestIndex: 1, usage: ledger)]);
    final prompt = stage1Map(stage1Map(summary['fields'])['prompt_tokens']);
    expect(prompt['knownSubtotal'], 0);
    expect(prompt['invalidRequestIndexes'], [1]);
    expect(prompt['complete'], isFalse);
    expect(prompt['total'], isNull);
  });

  test('bad nonstream usage is observed before a response error without synthetic normalized usage', () async {
    final reports = <ModelUsageReport>[];
    final context = ModelRequestContext(cancellation: ModelCancellation(), onUsageReport: reports.add);
    final client = _Client(
      (_) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'usage': [1, 2],
              'error': {'message': 'response failure'},
            }),
          ),
        ),
        200,
      ),
    );
    final deltas = <ModelDelta>[];
    await expectLater(
      TavernModelClient(
        clientFactory: () => client,
      ).generate(config: _config(), body: const {'stream': false}, cancellation: context).forEach(deltas.add),
      throwsA(isA<TavernModelException>()),
    );
    expect(reports.single.raw, [1, 2]);
    expect(reports.single.transport, 'nonstream');
    expect(deltas, isEmpty);
    expect(client.sent, 1);
  });

  test('usage presence, invalid numeric type, explicit zero and cache fallback stay distinct', () async {
    final reports = <ModelUsageReport>[];
    final context = ModelRequestContext(cancellation: ModelCancellation(), onUsageReport: reports.add);
    final client = _Client(
      (_) async => _sse([
        {
          'usage': {
            'prompt_tokens': 0,
            'completion_tokens': 0.0,
            'prompt_cache_hit_tokens': null,
            'prompt_tokens_details': {'cached_tokens': 5},
          },
          'choices': [],
        },
        {
          'choices': [
            {
              'delta': {'role': 'assistant'},
              'finish_reason': 'stop',
            },
          ],
        },
      ]),
    );
    final events = await TavernModelClient(
      clientFactory: () => client,
    ).generate(config: _config(), body: const {}, cancellation: context).toList();
    final report = reports.single;
    expect(stage1Map(report.fields['prompt_tokens'])['state'], 'reported');
    expect(stage1Map(report.fields['prompt_tokens'])['value'], 0);
    expect(stage1Map(report.fields['completion_tokens'])['state'], 'invalid');
    expect(stage1Map(report.fields['cache_hit_tokens'])['state'], 'reported');
    expect(stage1Map(report.fields['cache_hit_tokens'])['value'], 5);
    expect(stage1Map(report.fields['cache_hit_tokens'])['sourcePath'], 'usage.prompt_tokens_details.cached_tokens');
    expect(events.whereType<ModelFinished>().single.finalUsageReport!.toJson(), report.toJson());
    expect(events.whereType<ModelUsage>(), hasLength(1));

    final absentReports = <ModelUsageReport>[];
    final absent =
        await TavernModelClient(
              clientFactory: () => _Client(
                (_) async => _sse([
                  {
                    'choices': [
                      {
                        'delta': {'role': 'assistant', 'content': 'done'},
                        'finish_reason': 'stop',
                      },
                    ],
                  },
                ]),
              ),
            )
            .generate(
              config: _config(),
              body: const {},
              cancellation: ModelRequestContext(cancellation: ModelCancellation(), onUsageReport: absentReports.add),
            )
            .toList();
    expect(absentReports.single.origin, 'not_reported');
    expect(absentReports.single.rawPresent, isFalse);
    expect(absentReports.single.fields.values.map((field) => stage1Map(field)['state']), everyElement('missing'));
    expect(absent.whereType<ModelUsage>(), isEmpty);
  });

  test('request context delegates one cancellation truth and isolates observation callback failures', () async {
    final token = ModelCancellation();
    var calls = 0;
    final context = ModelRequestContext(
      cancellation: token,
      onUsageReport: (_) {
        calls++;
        throw StateError('observer failure');
      },
    );
    final attempts = <int>[];
    final client = _Client(
      (_) async => _sse([
        {
          'usage': null,
          'choices': [
            {
              'delta': {'role': 'assistant', 'content': 'body'},
              'finish_reason': 'stop',
            },
          ],
        },
      ]),
    );
    final events = await TavernModelClient(
      clientFactory: () => client,
    ).generate(config: _config(), body: const {}, cancellation: context, onRequestStarted: attempts.add).toList();
    expect(events.whereType<ModelText>().single.text, 'body');
    expect(events.whereType<ModelFinished>(), hasLength(1));
    expect(calls, 1);
    expect(attempts, [0]);
    context.closeObservations();
    context.reportUsage(stage1Usage(index: 4, prompt: 1, completion: 1, cache: 1));
    expect(calls, 1);
    final waiting = context.wait(Completer<void>().future);
    final checked = expectLater(
      waiting,
      throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.cancelled)),
    );
    context.cancel();
    await checked;
    expect(token.isCancelled, isTrue);
    expect(context.isCancelled, isTrue);
    await context.whenCancelled;
    expect(context.check, throwsA(isA<TavernModelException>()));
  });

  test('canonical ledger keeps observations immutable, deduplicates Finished and does not reselect old evidence', () {
    final first = stage1Usage(index: 2, prompt: 10, completion: 3, cache: 1);
    final second = stage1Usage(index: 2, prompt: 20, completion: 4, cache: 2);
    final one = recordToolUsageObservation(
      emptyToolUsageLedger(),
      report: first,
      normalizedUsage: const TavernUsage(promptTokens: 10, completionTokens: 3, cacheHitTokens: 1),
    );
    final original = jsonEncode(one.ledger);
    final two = recordToolUsageObservation(one.ledger, report: second);
    expect(two.diagnostics.map((item) => item['code']), contains('usage_observation_conflict'));
    final oldFinished = recordToolUsageObservation(two.ledger, report: first);
    expect(oldFinished.ledger['selectedObservationSequence'], 1);
    expect(stage1Rows(oldFinished.ledger['observations']), hasLength(2));
    expect(jsonEncode(one.ledger), original);
    expect(stage1Rows(oldFinished.ledger['observations']).first['normalizedUsage'], {
      'promptTokens': 10,
      'completionTokens': 3,
      'cacheHitTokens': 1,
      'model': null,
    });
    final withNormalized = recordToolUsageObservation(
      two.ledger,
      report: second,
      normalizedUsage: const TavernUsage(promptTokens: 20, completionTokens: 4, cacheHitTokens: 2),
    );
    expect(stage1Rows(withNormalized.ledger['observations']), hasLength(3));
    expect(withNormalized.ledger['selectedObservationSequence'], 2);
    expect(withNormalized.diagnostics.map((item) => item['code']), contains('usage_normalized_observed'));
  });

  test('summary preserves exact overflow and legacy unknown without filling missing values with zero', () {
    final maximum = stage1Usage(index: 0, prompt: 0x7fffffffffffffff, completion: 0, cache: 0);
    final one = recordToolUsageObservation(emptyToolUsageLedger(), report: maximum).ledger;
    final two = recordToolUsageObservation(
      emptyToolUsageLedger(),
      report: stage1Usage(index: 0, prompt: 1, completion: 0, cache: 0),
    ).ledger;
    final summary = summarizeToolUsage([(requestIndex: 1, usage: one), (requestIndex: 2, usage: two)]);
    final prompt = stage1Map(stage1Map(summary['fields'])['prompt_tokens']);
    expect(prompt['exactKnownSubtotal'], '9223372036854775808');
    expect(prompt['knownSubtotal'], isNull);
    expect(prompt['total'], isNull);
    expect(prompt['overflow'], isTrue);
    expect(prompt['invalidRequestIndexes'], isEmpty);
    expect(prompt['missingRequestIndexes'], isEmpty);
    expect(prompt['unknownRequestIndexes'], isEmpty);
    expect(completeToolUsage(summary), isNull);
    final legacy = recordToolUsageObservation(
      emptyToolUsageLedger(),
      report: ModelUsageReport.legacyNormalized(observationIndex: 0),
      normalizedUsage: const TavernUsage(promptTokens: 50, completionTokens: 10, cacheHitTokens: 0),
    ).ledger;
    final incomplete = summarizeToolUsage([(requestIndex: 1, usage: two), (requestIndex: 2, usage: legacy)]);
    final field = stage1Map(stage1Map(incomplete['fields'])['prompt_tokens']);
    expect(field['knownSubtotal'], 1);
    expect(field['unknownRequestIndexes'], [2]);
    expect(field['complete'], isFalse);
    expect(completeToolUsage(incomplete), isNull);
  });

  test('streaming cumulative usage stays in memory and seals once after the same request retries', () async {
    final source = StreamController<List<int>>();
    addTearDown(() {
      if (!source.isClosed) unawaited(source.close());
    });
    var sends = 0;
    final h = await _httpUsageHarness(
      TavernModelClient(
        clientFactory: () => _Client((_) async {
          sends++;
          if (sends == 1) return http.StreamedResponse(Stream.value(utf8.encode('{}')), 500);
          return http.StreamedResponse(source.stream, 200);
        }),
      ),
    );
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    final throughUsage = _throughText(events, 'usage-ready');
    for (var index = 0; index < 64; index++) {
      source.add(
        _frame({
          'usage': {'prompt_tokens': index + 1, 'completion_tokens': index + 2, 'prompt_cache_hit_tokens': 0},
          'choices': [],
        }),
      );
    }
    source.add(
      _frame({
        'choices': [
          {
            'delta': {'role': 'assistant', 'content': 'usage-ready'},
          },
        ],
      }),
    );
    await throughUsage;
    expect(_usageWrites(h), 0);
    expect(stage1Rows((await h.turn(events)).requests.single.usage['observations']), isEmpty);
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 64);
    source.add(
      _frame({
        'choices': [
          {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
      }),
    );
    source.add(utf8.encode('data: [DONE]\n\n'));
    await source.close();
    await events.done.future;
    final turn = await h.turn(events);
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(sends, 2);
    expect(turn.requests.single.sendAttempts, [0, 1]);
    expect(_usageWrites(h), 1);
    final observations = stage1Rows(turn.requests.single.usage['observations']);
    expect(observations, hasLength(1));
    expect(stage1Map(observations.single['report'])['observationIndex'], 63);
    expect(stage1Map(observations.single['normalizedUsage'])['promptTokens'], 64);
    expect(events.values.whereType<TavernTurnDone>().single.message.usage!.completionTokens, 65);
    expect(stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens'])['total'], 64);
    await h.reopen();
    expect((await h.engine.readToolTurn(turn.logicalTurnId))!.usageSummary, turn.usageSummary);
    expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 64);
  });

  test('accepted stream failure seals latest invalid raw with its last normalized provenance', () async {
    for (final multi in [false, true]) {
      final source = StreamController<List<int>>();
      addTearDown(() {
        if (!source.isClosed) unawaited(source.close());
      });
      var sends = 0;
      final h = await _httpUsageHarness(
        TavernModelClient(
          clientFactory: () => _Client((_) async {
            sends++;
            if (multi && sends == 1) {
              return _sse([
                {
                  'usage': {'prompt_tokens': 10, 'completion_tokens': 2, 'prompt_cache_hit_tokens': 1},
                  'choices': [],
                },
                {
                  'choices': [
                    {
                      'delta': {
                        'role': 'assistant',
                        'tool_calls': [
                          {
                            'index': 0,
                            ...Stage1Call(0, 'roll-usage', 'roll', {'dice': 'd6'}).wire,
                          },
                        ],
                      },
                      'finish_reason': 'tool_calls',
                    },
                  ],
                },
              ]);
            }
            return http.StreamedResponse(source.stream, 200);
          }),
        ),
      );
      final events = T24Events(h.engine.send(h.chatId, 'question'));
      final throughUsage = _throughText(events, 'partial');
      for (var index = 0; index < 4; index++) {
        source.add(
          _frame({
            'usage': {'prompt_tokens': 20 + index, 'completion_tokens': 3, 'prompt_cache_hit_tokens': 2},
            'choices': [],
          }),
        );
      }
      source.add(
        _frame({
          'choices': [
            {
              'delta': {'role': 'assistant', 'content': 'partial'},
            },
          ],
        }),
      );
      await throughUsage;
      expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, multi ? 33 : 23);
      expect(_usageWrites(h), multi ? 1 : 0);
      final throughInvalid = _throughText(events, '-invalid');
      source.add(
        _frame({
          'usage': null,
          'choices': [
            {
              'delta': {'content': '-invalid'},
            },
          ],
        }),
      );
      await throughInvalid;
      final live = (await h.engine.path(h.chatId)).last;
      expect(live.reportedUsage?.promptTokens, multi ? null : 23);
      expect(stage1Rows((await h.turn(events)).requests.last.usage['observations']), isEmpty);
      expect(_usageWrites(h), multi ? 1 : 0);
      source.addError(http.ClientException('accepted response interrupted'));
      await source.close();
      await events.done.future;
      final failed = events.values.whereType<TavernTurnFailed>().single;
      expect(failed.partial!.text, 'partial-invalid');
      expect(failed.partial!.reportedUsage?.promptTokens, multi ? null : 23);
      expect(events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(sends, multi ? 2 : 1);
      expect(_usageWrites(h), multi ? 2 : 1);
      final turn = await h.turn(events);
      final ledger = turn.requests.last.usage;
      final observations = stage1Rows(ledger['observations']);
      expect(observations, hasLength(2));
      expect(stage1Map(observations.first['report'])['observationIndex'], 3);
      expect(stage1Map(observations.first['normalizedUsage'])['promptTokens'], 23);
      expect(stage1Map(observations.last['report'])['raw'], isNull);
      expect(stage1Map(observations.last['report'])['observationIndex'], 4);
      expect(ledger['selectedObservationSequence'], 1);
      final summary = stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens']);
      expect(summary['knownSubtotal'], multi ? 10 : 0);
      expect(summary['invalidRequestIndexes'], [multi ? 2 : 1]);
      expect(summary['complete'], isFalse);
      expect(summary['total'], isNull);
      await h.reopen();
      expect((await h.engine.readToolTurn(turn.logicalTurnId))!.usageSummary, turn.usageSummary);
      expect((await h.engine.path(h.chatId)).last.reportedUsage?.promptTokens, multi ? null : 23);
    }
  });

  test('custom request observations belong to the original request and close before the next one', () async {
    final h = await Stage1Harness.open();
    final active = await h.start();
    final original = active.call.cancellation! as ModelRequestContext;
    final firstReport = stage1Usage(index: 0, prompt: 7, completion: 2, cache: 0);
    original.reportUsage(firstReport);
    final next = h.model.prepare();
    await stage1Finish(
      active.call,
      tools: [
        Stage1Call(0, 'r', 'roll', {'dice': 'd6'}),
      ],
      usageReport: firstReport,
    );
    await Stage1Harness.listening(next, active.events);
    original.reportUsage(stage1Usage(index: 99, prompt: 999, completion: 999, cache: 999));
    var turn = await h.turn(active.events);
    expect(stage1Rows(turn.requests.first.usage['observations']), hasLength(1));
    expect(stage1Rows(turn.requests.last.usage['observations']), isEmpty);
    final secondReport = stage1Usage(index: 0, prompt: 0, completion: 0, cache: 0);
    (next.cancellation! as ModelRequestContext).reportUsage(secondReport);
    await stage1Finish(next, content: 'done', usageReport: secondReport);
    await active.events.done.future;
    turn = await h.turn(active.events);
    expect(stage1Rows(turn.requests.last.usage['observations']), hasLength(1));
    expect(active.events.values.whereType<TavernTurnDone>().single.message.usage!.promptTokens, 7);
    expect(stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens'])['complete'], isTrue);
  });

  test('a committed invalid report clears the multi-request view despite persistent publication failure', () async {
    final h = await Stage1Harness.open(state: false);
    final active = await h.start();
    final next = h.model.prepare();
    final firstReport = stage1Usage(index: 0, prompt: 10, completion: 2, cache: 1);
    await stage1Finish(
      active.call,
      tools: [
        Stage1Call(0, 'durable-roll', 'roll', {'dice': 'd6'}),
      ],
      usageReport: firstReport,
      usage: const TavernUsage(promptTokens: 10, completionTokens: 2, cacheHitTokens: 1),
    );
    await Stage1Harness.listening(next, active.events);
    next.add(ModelText('retained partial'));
    final context = next.cancellation! as ModelRequestContext;
    context.reportUsage(stage1Usage(index: 0, prompt: 20, completion: 3, cache: 2));
    expect((await h.engine.path(h.chatId)).last.usage!.promptTokens, 30);
    final invalid = ModelUsageReport.fromJson({
      'version': 1,
      'origin': 'provider',
      'transport': 'custom',
      'observationIndex': 1,
      'observationComplete': true,
      'rawPresent': true,
      'raw': null,
      'fields': {
        for (final key in ['prompt_tokens', 'completion_tokens', 'cache_hit_tokens'])
          key: {'state': 'invalid', 'value': null, 'originalPresence': true, 'sourcePath': 'usage'},
      },
    });
    final failures = await _withFailingPublication(h, () => context.reportUsage(invalid), active.events.done.future);
    // The fault remains active for observation, response seal and terminal
    // adoption; a one-shot failure would let the old seal refresh hide the bug.
    expect(failures, greaterThanOrEqualTo(3));
    final failed = active.events.values.whereType<TavernTurnFailed>().single;
    expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(failed.partial!.text, 'retained partial');
    expect(failed.partial!.usage, isNull);
    expect(failed.partial!.reportedUsage, isNull);
    final turn = await h.turn(active.events);
    expect(turn.replyCommitAdopted, isTrue);
    expect(turn.normalFinalAdopted, isFalse);
    expect(turn.requests.last.responseComplete, isFalse);
    final prompt = stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens']);
    expect(prompt['knownSubtotal'], 10);
    expect(prompt['invalidRequestIndexes'], [2]);
    expect(prompt['complete'], isFalse);
    expect(prompt['total'], isNull);
    expect((await h.engine.readToolReceipt(turn.receiptIds.single))!.committed, isTrue);
    expect(h.model.generated, 2);
    expect(h.dice.calls, 1);
    await h.reopen();
    final saved = (await h.engine.path(h.chatId)).last;
    expect(saved.text, 'retained partial');
    expect(saved.usage, isNull);
    expect(saved.reportedUsage, isNull);
    expect((await h.engine.readToolTurn(turn.logicalTurnId))!.usageSummary, turn.usageSummary);
  });

  test(
    'single-request normalized adoption survives publication failure without inventing raw-only compatibility',
    () async {
      final h = await Stage1Harness.open(state: false);
      final active = await h.start();
      active.call.add(ModelText('single partial'));
      active.call.add(
        ModelUsage(
          const TavernUsage(promptTokens: 90, completionTokens: 9, cacheHitTokens: 0),
          report: stage1Usage(index: 0, prompt: 90, completion: 9, cache: 0),
        ),
      );
      (active.call.cancellation! as ModelRequestContext).reportUsage(
        stage1Usage(index: 1, prompt: 1, completion: 1, cache: 0),
      );
      expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 90);
      const actual = TavernUsage(promptTokens: 7, completionTokens: 2, cacheHitTokens: 0);
      final failures = await _withFailingPublication(
        h,
        () => active.call.add(ModelUsage(actual, report: stage1Usage(index: 2, prompt: 7, completion: 2, cache: 0))),
        active.events.done.future,
      );
      expect(failures, greaterThanOrEqualTo(3));
      final failed = active.events.values.whereType<TavernTurnFailed>().single;
      expect(failed.partial!.text, 'single partial');
      expect(failed.partial!.usage!.promptTokens, 7);
      expect(failed.partial!.reportedUsage!.promptTokens, 7);
      final turn = await h.turn(active.events);
      expect(turn.budgetUsed, 1);
      expect(turn.replyCommitAdopted, isTrue);
      expect(turn.normalFinalAdopted, isFalse);
      expect(stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens'])['total'], 7);
      expect(h.model.generated, 1);
      expect(h.dice.calls, 0);
      await h.reopen();
      expect((await h.engine.path(h.chatId)).last.usage!.promptTokens, 7);
      expect((await h.engine.path(h.chatId)).last.reportedUsage!.promptTokens, 7);
    },
  );

  test('a sole adopted ModelUsage remains an output when publication fails', () async {
    final h = await Stage1Harness.open(state: false);
    final active = await h.start();
    const actual = TavernUsage(promptTokens: 7, completionTokens: 2, cacheHitTokens: 0);
    // No text, reasoning or earlier usage can set the old output flag before
    // this ModelUsage is durably adopted and its notification throws.
    final failures = await _withFailingPublication(
      h,
      () => active.call.add(ModelUsage(actual, report: stage1Usage(index: 0, prompt: 7, completion: 2, cache: 0))),
      active.events.done.future,
    );
    expect(failures, greaterThanOrEqualTo(3));
    final failed = active.events.values.whereType<TavernTurnFailed>().single;
    expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(failed.partial, isNotNull);
    expect(failed.partial!.text, isEmpty);
    expect(failed.partial!.usage!.promptTokens, 7);
    expect(failed.partial!.reportedUsage!.promptTokens, 7);
    final turn = await h.turn(active.events);
    expect(turn.budgetUsed, 1);
    expect(turn.replyCommitAdopted, isTrue);
    expect(turn.normalFinalAdopted, isFalse);
    expect(turn.requests.single.responseComplete, isFalse);
    expect(stage1Map(stage1Map(turn.usageSummary['fields'])['prompt_tokens'])['total'], 7);
    expect(h.model.generated, 1);
    expect(h.dice.calls, 0);
    await h.reopen();
    final saved = await h.engine.path(h.chatId);
    expect(saved.where((message) => message.role == TavernRole.user).single.text, 'question');
    expect(saved.last.nodeId, failed.partial!.nodeId);
    expect(saved.last.text, isEmpty);
    expect(saved.last.usage!.promptTokens, 7);
    expect(saved.last.reportedUsage!.promptTokens, 7);
    expect((await h.engine.readToolTurn(turn.logicalTurnId))!.usageSummary, turn.usageSummary);
  });

  test('response snapshot copies exact arguments and index metadata without inventing provider identities', () {
    final tool = Stage1Call.raw(7, '\ufeffid', 'roll', ' {"dice":"d6"} ');
    final indexes = [7];
    final message = <String, Object?>{
      'role': 'assistant',
      'content': null,
      'tool_calls': [tool.wire],
    };
    final snapshot = ModelAssistantSnapshot.fromCustomMessage(message, callIndexes: indexes);
    indexes[0] = 2;
    message['content'] = 'later';
    expect(snapshot.completeForReplay, isTrue);
    expect(snapshot.calls.single.index, 7);
    expect(snapshot.calls.single.id, '\ufeffid');
    expect(snapshot.calls.single.arguments, ' {"dice":"d6"} ');
    expect(snapshot.wireMessage['content'], isNull);
    expect(stage1Rows(snapshot.wireMessage['tool_calls']).single.containsKey('index'), isFalse);
    expect(ModelAssistantSnapshot.fromJson(snapshot.toJson()).toJson(), snapshot.toJson());
    final missing = ModelAssistantSnapshot.fromCustomMessage({
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'type': 'function',
          'function': {'name': 'roll', 'arguments': '{"dice":"d6"}'},
        },
      ],
    });
    expect(missing.completeForReplay, isFalse);
    expect(missing.calls.single.id, isNull);
    expect(
      () => ModelAssistantSnapshot.fromCustomMessage(
        {
          'role': 'assistant',
          'tool_calls': [tool.wire],
        },
        callIndexes: [0, 1],
      ),
      throwsFormatException,
    );
  });

  test('roll name evidence survives rejected indexes and the 65th resource drop but never joins name fragments', () {
    final invalidIndex = ModelToolAccumulator()..add(ModelToolFragment(index: -1, name: 'roll', arguments: '{}'));
    expect(invalidIndex.finish().rollNameObserved, isTrue);
    final overflow = ModelToolAccumulator();
    for (var i = 0; i < 65; i++) {
      overflow.add(Stage1Call(i, 'id-$i', i == 64 ? 'roll' : 'update_state', {'ops': []}).fragment);
    }
    final batch = overflow.finish();
    expect(batch.rollNameObserved, isTrue);
    expect(batch.resourceOverflow, isTrue);
    expect(batch.calls, hasLength(64));
    final fragments = ModelToolAccumulator()
      ..add(ModelToolFragment(index: 0, id: 'id', type: 'function', name: 'ro', arguments: '{}'))
      ..add(ModelToolFragment(index: 0, name: 'll'));
    expect(fragments.finish().rollNameObserved, isFalse);
  });
}

Future<Stage1Harness> _httpUsageHarness(TavernModelClient model) async {
  final h = await Stage1Harness.open(state: false);
  await h.engine.close();
  h.engine = await TavernEngine.openDirectory(
    h.root,
    config: h.config,
    modelClient: model,
    clock: () => T24Harness.at,
    random: () => 0.25,
    rollRandom: h.dice.draw,
  );
  h.database(
    (database) => database.execute('''
    CREATE TABLE usage_writes(request_id TEXT NOT NULL);
    CREATE TRIGGER count_usage_writes AFTER UPDATE OF usage_json ON tool_requests BEGIN
      INSERT INTO usage_writes(request_id) VALUES(NEW.id);
    END;
  '''),
  );
  return h;
}

int _usageWrites(Stage1Harness h) =>
    h.database((database) => database.select('SELECT COUNT(*) AS n FROM usage_writes').single['n']! as int);

Future<void> _throughText(T24Events events, String text) {
  final reached = Completer<void>();
  events.subscription.onData((event) {
    events.values.add(event);
    if (event is TavernTextDelta && event.text == text && !reached.isCompleted) {
      reached.complete();
    }
  });
  return Future.any<void>([
    reached.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Turn ended before usage barrier: $text');
    }),
  ]);
}

/// VM-only fault injection at the existing real store notification boundary.
/// No product hook or alternate store/transaction implementation is installed.
Future<int> _withFailingPublication(Stage1Harness h, void Function() trigger, Future<void> settled) async {
  final library = mirrors.reflectClass(TavernEngine).owner as mirrors.LibraryMirror;
  final store =
      mirrors.reflect(h.engine).getField(mirrors.MirrorSystem.getSymbol('_store', library)).reflectee as ChatStore;
  final original = store.committedObserver;
  var failures = 0;
  store.committedObserver = (chatIds, presetsChanged) {
    original?.call(chatIds, presetsChanged);
    failures++;
    throw StateError('persistent post-commit publication failure');
  };
  try {
    trigger();
    await settled;
  } finally {
    store.committedObserver = original;
  }
  return failures;
}

TavernModelConfig _config() => TavernModelConfig(apiKey: () async => 'fixture-key', thinking: false);

List<int> _frame(Map<String, Object?> value) => utf8.encode('data: ${jsonEncode(value)}\n\n');

http.StreamedResponse _sse(List<Map<String, Object?>> values) => http.StreamedResponse(
  Stream.fromIterable([for (final value in values) _frame(value), utf8.encode('data: [DONE]\n\n')]),
  200,
);

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  int sent = 0;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    return respond(request);
  }

  @override
  void close() {
    closed = true;
  }
}
