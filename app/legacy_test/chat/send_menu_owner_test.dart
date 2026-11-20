import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_insert.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

// Controlled frames through the real DshMux, with no socket or altered mux code.
class _HistoryCarrier extends FakeRpcCarrier {
  _HistoryCarrier() : super({});
  _HistoryLink? latest;
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => latest = _HistoryLink();
}

class _HistoryLink implements DshMuxLink {
  late DshMuxFrameHandler frame;
  String? eventsId;
  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String id, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') eventsId = id;
  }

  void ready() => frame({
    'type': 'item',
    'streamId': eventsId!,
    'value': {
      'type': 'ready',
      'clientId': 'menu-generation',
      'host': {'home': '/synthetic/home'},
    },
  });
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

void main() {
  for (final change in ['session', 'new draft', 'session roundtrip', 'insert', 'quote', 'unchanged']) {
    testWidgets('send-mode selection retains its opening intent after $change', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      SharedPreferences.setMockInitialValues({});
      final ui = ChatHarness(
        session: 'A',
        states: {
          'A': const ChatState(loading: false, running: true),
          'B': const ChatState(loading: false, running: true),
        },
      );
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: ui.overrides));
      await pumpFrames(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      try {
        container.read(draftStoreProvider.notifier).save('B', 'other conversation draft', []);
        container.read(draftStoreProvider.notifier).save('new', 'new conversation draft', []);
        await tester.enterText(find.byType(TextField), 'original draft');
        await pumpFrames(tester);
        await tester.longPress(find.byIcon(AppIcons.send));
        await pumpFrames(tester);
        expect(find.text('发送方式'), findsOneWidget);
        final selector = container.read(currentSessionProvider.notifier);
        switch (change) {
          case 'session':
            selector.select('B');
          case 'new draft':
            selector.select(null);
          case 'session roundtrip':
            selector.select('B');
            selector.select('A');
          case 'insert':
            container
                .read(composerInsertProvider.notifier)
                .request(const ComposerInsert(token: 'inserted', sessionId: 'A'));
          case 'quote':
            container.read(composerQuoteProvider.notifier).set('A', 'a newly chosen quote');
        }
        await pumpFrames(tester);
        final before = tester.widget<TextField>(find.byType(TextField)).controller!.text;
        await tester.tap(find.text('排队'));
        await pumpFrames(tester);
        if (change == 'unchanged') {
          expect(ui.controllers['A']!.sent, ['original draft']);
          expect(ui.controllers['A']!.sentModes, [SendMode.queue]);
        } else {
          expect(ui.controllers.values.expand((controller) => controller.sent), isEmpty);
          expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, before);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      }
    });
  }

  testWidgets('a null-ready-null mux history cannot revive a send menu', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    SharedPreferences.setMockInitialValues({});
    final carrier = _HistoryCarrier();
    final client = DshClient.withCarrier(carrier);
    final connection = HostConnection(hostId: '', client: client, isLocal: true);
    final ui = ChatHarness(session: 'A', states: {'A': const ChatState(loading: false, running: true)});
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          for (final override in ui.overrides)
            if (override.origin != activeConnectionProvider) override,
          activeConnectionProvider.overrideWithValue(AsyncData(connection)),
        ],
      ),
    );
    await pumpFrames(tester);
    try {
      await tester.enterText(find.byType(TextField), 'original generation draft');
      await pumpFrames(tester);
      await tester.longPress(find.byIcon(AppIcons.send));
      await pumpFrames(tester);
      expect(find.text('发送方式'), findsOneWidget);
      expect(client.mux.generation, isNull);
      final ready = client.mux.ready();
      await tester.pump();
      expect(carrier.latest!.eventsId, isNotNull);
      carrier.latest!.ready();
      await tester.pump();
      await ready;
      await client.close();
      expect(client.mux.generation, isNull);
      expect(client.mux.lastReadyGenerationNumber, 1);
      await tester.tap(find.text('排队'));
      await pumpFrames(tester);
      expect(ui.controllers['A']!.sent, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'original generation draft');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      await client.close();
    }
  });
}
