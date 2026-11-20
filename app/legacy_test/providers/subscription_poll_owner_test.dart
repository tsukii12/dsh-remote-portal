import 'dart:async';

import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_app/ui/providers/subscription_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/account.dart' show FakeBrowser;
import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(onPressed: () => showSubscriptionLogin(context, Subscription.chatgpt), child: const Text('open')),
  );
}

void main() {
  for (final scenario in ['old success', 'old error', 'close in flight']) {
    testWidgets('one poll chain after answer: $scenario', (tester) async {
      final wire = FakePluginCarrier();
      final client = DshClient.withCarrier(wire);
      final held = <int, Completer<Object?>>{};
      Completer<Object?>? answer;
      var phase = 'prompt';
      var polls = 0;
      wire.handlers['appAuth/begin'] = (_) => {'attemptId': 'attempt-1'};
      wire.handlers['appAuth/poll'] = (args) {
        expect(args['attemptId'], 'attempt-1');
        final snapshot = <String, Object?>{'phase': phase};
        final index = ++polls;
        if (index == 2 || index == 3) {
          expect(snapshot['phase'], 'starting');
          final gate = Completer<Object?>();
          held[index] = gate;
          return gate.future;
        }
        return snapshot;
      };
      wire.handlers['appAuth/answer'] = (args) {
        expect(args, {'attemptId': 'attempt-1', 'value': 'one-code'});
        // The real bridge consumes the answer synchronously before replying.
        // Delay delivery of that reply, not the state transition itself.
        phase = 'starting';
        answer = Completer<Object?>();
        return answer!.future;
      };
      wire.handlers['appAuth/cancel'] = (_) => <String, Object?>{};

      await tester.runAsync(loadGoldenFonts);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1800);
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          goldenApp(
            home: const _Opener(),
            brightness: Brightness.light,
            overrides: [
              subscriptionBackendProvider.overrideWithValue(ClientSubscriptionBackend(client)),
              accountBrowserProvider.overrideWithValue(FakeBrowser()),
            ],
          ),
        );
        await settle(tester);
        await tester.tap(find.text('open'));
        await settle(tester);
        expect(polls, 1);
        await tester.enterText(find.byType(TextField), 'one-code');
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, '确定').hitTestable());
        await tester.pump();
        expect(answer, isNotNull, reason: 'the real UI submission reached the SDK carrier');
        expect(wire.argsOf('appAuth/answer'), hasLength(1));

        // The unchanged one-second timer fires while the answer ACK is pending.
        await tester.pump(const Duration(seconds: 1));
        expect(polls, 2);
        expect(held[2], isNotNull);
        answer!.complete(<String, Object?>{});
        await tester.pump();
        expect(polls, 3, reason: 'ACK causes one immediate fresh poll');
        expect(held[3], isNotNull);

        if (scenario == 'close in flight') {
          await tester.tap(find.byTooltip('关闭').hitTestable());
          await settle(tester);
          expect(find.byType(SubscriptionLoginSheet), findsNothing);
        }
        if (scenario == 'old error') {
          held[2]!.completeError(const DshTransportException('response lost'));
        } else {
          held[2]!.complete({'phase': 'starting'});
        }
        await tester.pump();
        held[3]!.complete({'phase': 'starting'});
        await tester.pump();
        expect(polls, 3, reason: 'both actual pending responses have settled');

        await tester.pump(const Duration(seconds: 1));
        expect(polls, scenario == 'close in flight' ? 3 : 4);
        expect(wire.argsOf('appAuth/answer'), hasLength(1));
        if (scenario != 'close in flight') {
          await tester.pump(const Duration(seconds: 1));
          expect(polls, 5, reason: 'the single chain continues at the original interval');
          await tester.tap(find.byTooltip('关闭').hitTestable());
          await settle(tester);
        }
        final closedPolls = polls;
        await tester.pump(const Duration(seconds: 2));
        expect(polls, closedPolls, reason: 'closing stops all future SDK polls');
        expect(tester.takeException(), isNull);
      } finally {
        // Release only operations that actually entered the carrier.
        if (answer case final gate? when !gate.isCompleted) gate.complete(<String, Object?>{});
        for (final gate in held.values) {
          if (!gate.isCompleted) gate.complete({'phase': 'starting'});
        }
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await client.close();
      }
    });
  }
}
