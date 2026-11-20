import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/pending_notice_harness.dart';

Future<PendingNoticeHarness> _mount(
  WidgetTester tester, {
  required Locale locale,
  double width = 320,
  double scale = 1.3,
  String slot = 'next-turn',
  bool running = true,
}) async {
  AppLocale.use(locale);
  addTearDown(() => AppLocale.use(AppLocale.zhCN));
  final h = PendingNoticeHarness();
  addTearDown(h.dispose);
  await h.mount(tester);
  tester.view.physicalSize = Size(width * tester.view.devicePixelRatio, 844 * tester.view.devicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  h.snapshot([
    pendingMessage(
      id: 'queued-item',
      text: 'A queued request',
      source: const {'kind': 'user', 'rpcId': 'queued-request'},
    ),
  ], slot: slot);
  h.running(running);
  await h.settle(tester);
  expect(h.state.pending.single.inboxId, 'queued-item');
  expect(h.state.running, running);
  expect(h.state.controlReady, isTrue);
  return h;
}

void _visible(WidgetTester tester, Finder finder, double width) {
  expect(finder, findsOneWidget);
  final box = tester.getRect(finder);
  expect(box.left, greaterThanOrEqualTo(0));
  expect(box.right, lessThanOrEqualTo(width));
  expect(box.top, greaterThanOrEqualTo(0));
  expect(box.bottom, lessThanOrEqualTo(844));
  if (tester.renderObject(finder) case final RenderParagraph paragraph) {
    expect(paragraph.didExceedMaxLines, isFalse);
  }
}

void main() {
  setUpAll(loadTestFonts);
  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('queued actions remain readable and tappable at 320dp: $locale $scale', (tester) async {
        final h = await _mount(tester, locale: locale, scale: scale);
        expect(tester.takeException(), isNull);
        final l10n = appL10n;
        _visible(tester, find.text(l10n.chatQueuedAfterTurn), 320);
        final labels = [l10n.chatSendNow, l10n.chatSwitchToSteer, l10n.chatWithdraw];
        for (final label in labels) {
          _visible(tester, find.widgetWithText(TextButton, label), 320);
          _visible(tester, find.text(label), 320);
        }
        await tester.tap(find.text(l10n.chatSendNow));
        await h.settle(tester);
        expect(h.sentNow.single.inboxId, 'queued-item');
        await tester.tap(find.text(l10n.chatSwitchToSteer));
        await h.settle(tester);
        expect(h.client.calls, ['steer:queued-item']);
        await tester.tap(find.text(l10n.chatWithdraw));
        await h.settle(tester);
        expect(h.withdrawn.single.inboxId, 'queued-item');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final running in [false, true]) {
    testWidgets('next-step actions retain their mode at narrow width: running=$running', (tester) async {
      final h = await _mount(tester, locale: AppLocale.en, slot: 'next-step', running: running);
      expect(tester.takeException(), isNull);
      final l10n = appL10n;
      final label = running ? l10n.chatSteerNextStep : l10n.chatUnsent;
      _visible(tester, find.text(label), 320);
      expect(find.text(l10n.chatSwitchToSteer), findsNothing);
      final send = running ? l10n.chatSendNow : l10n.commonSend;
      for (final action in [send, l10n.chatWithdraw]) {
        _visible(tester, find.widgetWithText(TextButton, action), 320);
        await tester.tap(find.text(action));
        await h.settle(tester);
      }
      expect(h.sentNow.single.inboxId, 'queued-item');
      expect(h.withdrawn.single.inboxId, 'queued-item');
      expect(h.client.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide pending metadata keeps one row and action order', (tester) async {
    await _mount(tester, locale: AppLocale.en, width: 800, scale: 1);
    expect(tester.takeException(), isNull);
    final l10n = appL10n;
    final centers = [
      tester.getCenter(find.text(l10n.chatQueuedAfterTurn)),
      for (final label in [l10n.chatSendNow, l10n.chatSwitchToSteer, l10n.chatWithdraw])
        tester.getCenter(find.widgetWithText(TextButton, label)),
    ];
    for (var i = 1; i < centers.length; i++) {
      expect(centers[i].dy, closeTo(centers.first.dy, 0.01));
      expect(centers[i].dx, greaterThan(centers[i - 1].dx));
    }
    expect(find.byType(UserBubble), findsOneWidget);
  });
}
