import 'dart:async';

import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/ui/chat/balance_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Balance extends BalanceController {
  @override
  BalanceState build() => const BalanceState(
    status: BalanceStatus.ok,
    balance: DeepSeekBalance(currency: 'CNY', total: 3.2),
  );

  @override
  Future<void> refresh() async {}
}

List<MethodCall> _launchResult(WidgetTester tester, Future<bool> Function() result) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
    calls.add(call);
    return result();
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  return calls;
}

Future<void> _openEntry(WidgetTester tester, {required bool settings}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: settings ? const BalanceSettingsLine() : const LowBalanceBanner(),
        ),
      ),
      overrides: [balanceProvider.overrideWith(_Balance.new)],
    ),
  );
  await tester.pumpAndSettle();
  if (settings) {
    await tester.tap(find.byType(BalanceSettingsLine));
    await tester.pumpAndSettle();
    expect(find.byType(BalanceCard), findsOneWidget);
  }
}

void main() {
  setUpAll(loadTestFonts);

  for (final settings in [true, false]) {
    final entry = settings ? 'balance sheet' : 'low-balance banner';
    for (final outcome in ['false', 'exception', 'success']) {
      testWidgets('$entry reports browser $outcome without losing the entry', (tester) async {
        final calls = _launchResult(tester, () async {
          if (outcome == 'exception') throw PlatformException(code: 'SYNTHETIC_NO_BROWSER');
          return outcome == 'success';
        });
        await _openEntry(tester, settings: settings);
        await tester.tap(find.text('去充值'));
        await tester.pumpAndSettle();

        expect(calls, hasLength(1));
        expect(calls.single.method, 'launch');
        expect((calls.single.arguments as Map)['url'], deepSeekTopUpUrl);
        expect((calls.single.arguments as Map)['useWebView'], isFalse);
        expect((calls.single.arguments as Map)['headers'], isEmpty);
        if (outcome == 'success') {
          expect(find.text('没能打开浏览器'), findsNothing);
        } else {
          // A notice behind the modal balance sheet does not reach the user.
          expect(find.text('没能打开浏览器').hitTestable(), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
        }
        expect(find.text('去充值').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final throws in [false, true]) {
    testWidgets('dismissed balance sheet ignores late browser ${throws ? 'exception' : 'false'}', (tester) async {
      final pending = Completer<bool>();
      final calls = _launchResult(tester, () => pending.future);
      await _openEntry(tester, settings: true);
      await tester.tap(find.text('去充值'));
      await tester.pump();
      expect(calls, hasLength(1));

      Navigator.of(tester.element(find.byType(BalanceCard))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BalanceCard), findsNothing);
      if (throws) {
        pending.completeError(PlatformException(code: 'SYNTHETIC_NO_BROWSER'));
      } else {
        pending.complete(false);
      }
      await tester.pumpAndSettle();

      expect(find.text('没能打开浏览器'), findsNothing);
      expect(find.byType(BalanceSettingsLine), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
