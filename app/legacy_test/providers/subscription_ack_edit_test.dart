import 'dart:async';

import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/ui/providers/subscription_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/account.dart' show FakeBrowser;
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

typedef _Outcome = ({Object? error, StackTrace? stack});
Future<_Outcome> _observe(Future<void> future) => future.then<_Outcome>(
  (_) => (error: null, stack: null),
  onError: (Object error, StackTrace stack) => (error: error, stack: stack),
);

class _Bridge extends FakeSubscriptionBackend {
  final answerGate = Completer<void>();
  final operations = <Future<_Outcome>>[];
  final pollFailure = const DshTransportException('post-ACK poll failure');
  Future<_Outcome>? pollTerminal;
  bool answerStarted = false;

  @override
  Future<void> answer(String attemptId, String value) {
    answerStarted = true;
    calls.add('answer:$attemptId:$value');
    final future = answerGate.future;
    operations.add(_observe(future));
    return future;
  }

  @override
  Future<LoginStep> poll(String attemptId) {
    calls.add('poll:$attemptId');
    if (polls == 1) return Future.value(const LoginStep(phase: LoginPhase.prompt, message: 'Paste code'));
    final future = Future<LoginStep>.error(pollFailure);
    pollTerminal = future.then<_Outcome>(
      (_) => (error: null, stack: null),
      onError: (Object error, StackTrace stack) => (error: error, stack: stack),
    );
    return future;
  }

  @override
  Future<void> cancel(String attemptId) {
    final future = super.cancel(attemptId);
    operations.add(_observe(future));
    return future;
  }

  Future<void> joinStarted() async {
    for (final future in List.of(operations)) {
      final outcome = await future;
      if (outcome.error case final error?) Error.throwWithStackTrace(error, outcome.stack!);
    }
    final poll = pollTerminal;
    if (poll != null) {
      final outcome = await poll;
      expect(outcome.error, same(pollFailure));
    }
  }
}

class _Opener extends StatefulWidget {
  const _Opener({super.key});
  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  String result = 'none';
  Future<_Outcome>? completion;
  Future<void> _show() async {
    final value = await showSubscriptionLogin(context, Subscription.chatgpt);
    setState(() => result = '$value');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('result: $result'),
        TextButton(onPressed: () => completion = _observe(_show()), child: const Text('open')),
      ],
    ),
  );
}

void main() {
  testWidgets('ACK preserves text edited while the first answer is in flight', (tester) async {
    final bridge = _Bridge();
    final opener = GlobalKey<_OpenerState>();
    await tester.runAsync(loadGoldenFonts);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1800);
    tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(
        goldenApp(
          home: _Opener(key: opener),
          brightness: Brightness.light,
          overrides: [
            ...providerOverrides(FakeProviderBackend(), subscriptions: bridge),
            accountBrowserProvider.overrideWithValue(FakeBrowser()),
          ],
        ),
      );
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(bridge.polls, 1);
      await tester.enterText(find.byType(TextField), 'first-code');
      await tester.pump();
      final confirm = find.widgetWithText(FilledButton, '确定').hitTestable();
      expect(confirm, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pump();
      expect(bridge.answerStarted, isTrue);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'new-input');
      await tester.pump();
      bridge.answerGate.complete();
      await tester.pump();
      expect(bridge.polls, 2);
      await bridge.joinStarted();
      await tester.pump(const Duration(milliseconds: 240));
      expect(bridge.polls, 2);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'new-input');
      expect(bridge.calls.where((call) => call.startsWith('answer:')), ['answer:att-1:first-code']);
      expect(tester.takeException(), isNull);
    } finally {
      if (!bridge.answerGate.isCompleted) bridge.answerGate.complete();
      try {
        try {
          await tester.pump();
          if (find.byType(SubscriptionLoginSheet).evaluate().isNotEmpty) {
            final close = find.byTooltip('关闭').hitTestable();
            expect(close, findsOneWidget);
            await tester.tap(close);
            await settle(tester);
            expect(find.byType(SubscriptionLoginSheet), findsNothing);
            expect(find.text('result: false'), findsOneWidget);
          }
          final completion = opener.currentState?.completion;
          if (completion != null) {
            final outcome = await completion;
            if (outcome.error case final error?) Error.throwWithStackTrace(error, outcome.stack!);
          }
        } finally {
          await bridge.joinStarted();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}
