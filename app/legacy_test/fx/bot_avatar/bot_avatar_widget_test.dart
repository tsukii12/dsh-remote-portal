// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('a working avatar animates, an idle one is a still frame', (tester) async {
    /* crisp needs no bake, so the still path is taken at once */
    await tester.pumpWidget(_host(const BotAvatar(id: 'a', shading: BotAvatarShading.crisp, size: 48)));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.bySemanticsLabel(RegExp(r'bot, idle$')), findsOneWidget);

    await tester.pumpWidget(
      _host(const BotAvatar(id: 'a', shading: BotAvatarShading.crisp, size: 48, state: BotAvatarState.working)),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(tester.takeException(), isNull);

    /* back to idle: awake for the switch, then still again */
    await tester.pumpWidget(_host(const BotAvatar(id: 'a', shading: BotAvatarShading.crisp, size: 48)));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a tap wakes a still avatar for its jump', (tester) async {
    await tester.pumpWidget(_host(const BotAvatar(type: BotAvatarType.star, shading: BotAvatarShading.smooth)));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(find.byType(BotAvatar));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows the still pose and never loops', (tester) async {
    await tester.pumpWidget(
      _host(const BotAvatar(id: 'b', shading: BotAvatarShading.flat, state: BotAvatarState.working), reduced: true),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.tap(find.byType(BotAvatar), warnIfMissed: false);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('every type and state paints in each vector shading', (tester) async {
    for (final shading in [BotAvatarShading.crisp, BotAvatarShading.smooth, BotAvatarShading.flat]) {
      await tester.pumpWidget(
        _host(
          Wrap(
            children: [
              for (final t in BotAvatarType.values)
                for (final s in BotAvatarState.values)
                  BotAvatar(type: t, state: s, shading: shading, size: 24, face: BotAvatarFace.mouth, live: false),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a plush avatar waits for its bake without throwing', (tester) async {
    await tester.pumpWidget(_host(const BotAvatar(id: 'c', state: BotAvatarState.working, size: 96)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
