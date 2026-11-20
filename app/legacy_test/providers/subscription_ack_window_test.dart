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
  _Bridge(this.failPostAck);

  final bool failPostAck;
  final failure = const DshTransportException('post-ACK poll transport failure');
  final operations = <(String, Future<_Outcome>)>[];
  final settled = <String>[];
  bool postAckHadSettledAnswer = false;
  int answers = 0;

  Future<T> _record<T>(String name, Future<T> future) {
    final terminal = future.then<_Outcome>(
      (_) {
        settled.add(name);
        return (error: null, stack: null);
      },
      onError: (Object error, StackTrace stack) {
        settled.add(name);
        return (error: error, stack: stack);
      },
    );
    operations.add((name, terminal));
    return future;
  }

  @override
  Future<LoginStep> poll(String attemptId) {
    calls.add('poll:$attemptId');
    final index = polls;
    if (index == 1) {
      return _record('poll1', Future.value(const LoginStep(phase: LoginPhase.prompt, message: 'Paste the code')));
    }
    if (index == 2) {
      postAckHadSettledAnswer = answers == 1 && settled.contains('answer1');
      return _record(
        'poll2',
        failPostAck ? Future<LoginStep>.error(failure) : Future.value(const LoginStep(phase: LoginPhase.starting)),
      );
    }
    return _record('poll$index', Future.value(const LoginStep(phase: LoginPhase.starting)));
  }

  @override
  Future<void> answer(String attemptId, String value) {
    answers++;
    return _record('answer$answers', super.answer(attemptId, value));
  }

  @override
  Future<void> cancel(String attemptId) => _record('cancel', super.cancel(attemptId));

  Future<void> joinStarted() async {
    for (final operation in List.of(operations)) {
      final outcome = await operation.$2;
      final error = outcome.error;
      if (error != null && !(operation.$1 == 'poll2' && failPostAck && identical(error, failure))) {
        Error.throwWithStackTrace(error, outcome.stack!);
      }
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
    final ok = await showSubscriptionLogin(context, Subscription.chatgpt);
    setState(() => result = '$ok');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('result: $result'),
          TextButton(onPressed: () => completion = _observe(_show()), child: const Text('open')),
        ],
      ),
    ),
  );
}

void main() {
  for (final failPostAck in [false, true]) {
    testWidgets('ACK does not submit the same input twice after poll failure=$failPostAck', (tester) async {
      final bridge = _Bridge(failPostAck);
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
        expect(bridge.calls.where((call) => call.startsWith('begin:')), ['begin:openai-codex']);
        expect(bridge.calls.where((call) => call.startsWith('poll:')), ['poll:att-1']);
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), '  first-code#state  ');
        await tester.pump();
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '  first-code#state  ');
        final firstConfirm = find.widgetWithText(FilledButton, '确定').hitTestable();
        expect(firstConfirm, findsOneWidget);
        expect(tester.widget<FilledButton>(firstConfirm).onPressed, isNotNull);
        await tester.tap(firstConfirm);
        await tester.pump();
        expect(bridge.answers, 1);
        expect(bridge.polls, 2, reason: 'the next poll is actually started by the successful answer');
        await bridge.joinStarted();
        expect(bridge.postAckHadSettledAnswer, isTrue);
        final secondPoll = bridge.operations.singleWhere((operation) => operation.$1 == 'poll2');
        final outcome = await secondPoll.$2;
        expect(outcome.error, failPostAck ? same(bridge.failure) : isNull);
        if (failPostAck) expect(outcome.error, isA<DshTransportException>());
        expect(bridge.calls.where((call) => call.startsWith('answer:')), ['answer:att-1:first-code#state']);

        // One normal UI frame after the reply: well before the unchanged one-second polling interval.
        await tester.pump(const Duration(milliseconds: 240));
        expect(bridge.polls, 2, reason: 'no timer poll was used to create the observation window');
        if (!failPostAck) {
          expect(find.byKey(const ValueKey('starting')), findsOneWidget);
          expect(find.byKey(const ValueKey('prompt')), findsNothing, reason: 'the old prompt transition has ended');
        }
        final currentConfirm = find.widgetWithText(FilledButton, '确定').hitTestable();
        expect(currentConfirm.evaluate().length, lessThanOrEqualTo(1));
        if (currentConfirm.evaluate().isNotEmpty && tester.widget<FilledButton>(currentConfirm).onPressed != null) {
          await tester.tap(currentConfirm);
          await tester.pump();
          await bridge.joinStarted();
        }
        expect(bridge.calls.where((call) => call.startsWith('answer:')), [
          'answer:att-1:first-code#state',
        ], reason: 'the user did not enter a new answer after the successful ACK');
        expect(tester.takeException(), isNull);
      } finally {
        try {
          try {
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
}
