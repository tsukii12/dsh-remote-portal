import 'dart:async';

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Only transport is controlled: parsing, transcript, controller and list are real.
class PendingNoticeClient extends DshClient {
  PendingNoticeClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final calls = <String>[];
  final sent = <({String text, String? requestId})>[];

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<void> updateQueue(
    String sessionId,
    String itemId, {
    String? editText,
    bool remove = false,
    bool steer = false,
  }) async {
    calls.add('${remove ? 'remove' : 'steer'}:$itemId');
  }

  @override
  Future<void> cancel(String sessionId) async => calls.add('cancel:$sessionId');

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
    calls.add('prompt:${mode.wire}:$text');
    sent.add((text: text, requestId: requestId));
    return requestId ?? 'request';
  }
}

const backgroundNoticeBody = 'background job job-123 finished: npm run build\nUse job_output to read its output.';

Map<String, Object?> pendingMessage({
  String id = 'notice-1',
  String text = backgroundNoticeBody,
  Object? source = const {'kind': 'tool-jobs', 'form': 'notice', 'summary': 'Do not use as identity'},
}) => {
  'id': id,
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': ?source,
};

class PendingNoticeHarness {
  PendingNoticeHarness() {
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true))),
        settingsProvider.overrideWith(TestSettings.new),
        sessionArtifactsProvider('s').overrideWithValue(const []),
      ],
    );
    container.listen(chatProvider('s'), (_, _) {});
  }

  final client = PendingNoticeClient();
  late final ProviderContainer container;
  final withdrawn = <PendingPrompt>[];
  final sentNow = <PendingPrompt>[];
  int seq = 0;

  ChatController get chat => container.read(chatProvider('s').notifier);
  ChatState get state => container.read(chatProvider('s'));

  void snapshot(List<Map<String, Object?>> messages, {String slot = 'next-step', bool resync = false}) {
    client.events.add(
      parseFollowFrame('s', {
        'type': 'snapshot',
        'header': {'id': 's', 'createdAt': 1792700000000},
        'cursor': seq,
        'records': const [],
        'hasMore': false,
        'projections': {
          'asOfSeq': seq,
          'values': {
            'inbox': {slot: messages},
          },
        },
      }, isResync: resync),
    );
  }

  void splice(List<Map<String, Object?>> messages, {String slot = 'next-step', int removed = 0}) =>
      log('agent/inbox/spliced', {'target': slot, 'start': 0, 'removedCount': removed, 'inserted': messages});

  void log(String type, Map<String, Object?> data) => client.events.add(
    parseFollowFrame('s', {
      'type': 'event',
      'event': {'seq': ++seq, 'time': 1792700000000 + seq, 'type': type, 'data': data},
    }),
  );

  void running(bool value) => client.events.add(SessionStatusEvent('s', value));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> mount(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          home: Scaffold(
            body: ChatList(
              sessionId: 's',
              topInset: 0,
              bottomInset: 0,
              onWithdraw: withdrawn.add,
              onSendNow: sentNow.add,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> dispose() async {
    container.dispose();
    await client.events.close();
  }
}
