import 'package:dsh_app/ui/bots/bot_avatar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final size in [32.0, 40.0, 56.0, 64.0]) {
    testWidgets('stacked avatars leave the rear letter clear at $size', (tester) async {
      final team = DsBotTeam.fromJson(sampleTeam(working: false));
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Scaffold(
            body: Center(
              child: RoomAvatar(room: team.room('r1')!, team: team, size: size),
            ),
          ),
        ),
      );
      await tester.pump();
      final tile = tester.getRect(find.byType(RoomAvatar));
      final faces = find.byType(BotAvatar);
      final back = tester.getRect(faces.first);
      final front = tester.getRect(faces.last);
      final glyph = tester.getRect(find.text('C'));
      final gap = (size * .05).clamp(1.5, 3.0);
      for (final point in [glyph.topLeft, glyph.topRight, glyph.bottomLeft, glyph.bottomRight]) {
        expect((point - front.center).distance, greaterThan(front.width / 2 + gap + .5));
      }
      expect(back.width, closeTo(size * .6, .01));
      expect(back.height, closeTo(size * .6, .01));
      expect(front.size, back.size);
      expect(back.left, tile.left);
      expect(back.top, tile.top);
      expect(front.right, tile.right);
      expect(front.bottom, tile.bottom);
      expect(back.center.dx + front.center.dx, closeTo(tile.center.dx * 2, .5));
      expect(back.center.dy + front.center.dy, closeTo(tile.center.dy * 2, .5));
    });
  }
}
