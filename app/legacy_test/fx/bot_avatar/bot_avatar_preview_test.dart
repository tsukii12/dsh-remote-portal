// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Renders preview frames when asked:
//   flutter test test/fx/bot_avatar/bot_avatar_preview_test.dart --dart-define=FX_PREVIEW_OUT=<dir>

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_bakery.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_color.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_paint.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');

Future<void> _warm(BotAvatarLook look, double box, double dpr) async {
  for (var i = 0; i < 600 && !botAvatarReady(look, box, dpr); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(botAvatarReady(look, box, dpr), isTrue, reason: '${look.type.name} ${look.shading.name} did not bake');
  while (BotAvatarBakery.instance.pending) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> _png(ui.Image img, String name) async {
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

/* one frame of a look and pose on a backdrop, straight through the painter */
Future<ui.Image> _frame(BotAvatarLook look, BotAvatarPose pose, BotAvatarRenderState rs, double box, Color bg) {
  const dpr = 2.0;
  final full = box * botAvatarOverscan;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..scale(dpr);
  c.drawRect(Rect.fromLTWH(0, 0, full, full), Paint()..color = bg);
  paintBotAvatar(c, box, pose, look, rs, dpr: dpr, still: false);
  return rec.endRecording().toImage((full * dpr).round(), (full * dpr).round());
}

void main() {
  testWidgets('bot avatar preview frames', skip: out.isEmpty, (tester) async {
    Directory(out).createSync(recursive: true);
    const light = Color(0xFFF6F5F2), dark = Color(0xFF15161B);
    /* the widget itself first (the piles of the type sheet below would crowd the
       pile cache): theme palette from ids, still frames, light and dark */
    for (final (bgName, brightness) in [('light', Brightness.light), ('dark', Brightness.dark)]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: const Color(0xFF4D7CFF), brightness: brightness),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: Container(
                  color: brightness == Brightness.light ? light : dark,
                  padding: const EdgeInsets.all(24),
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 28,
                    children: [
                      for (var i = 0; i < 12; i++)
                        BotAvatar(id: 'agent-$i', size: i < 6 ? 48 : 32, state: BotAvatarState.values[i % 3]),
                      for (var i = 0; i < 6; i++)
                        BotAvatar(
                          id: 'preset-$i',
                          size: 32,
                          shading: BotAvatarShading.plastic,
                          state: BotAvatarState.values[i % 3],
                        ),
                      for (var i = 0; i < 6; i++)
                        BotAvatar(type: BotAvatarType.values[i * 3], palette: BotAvatarPalette.author, size: 40),
                      const BotAvatar(id: 'empty-state', size: 128),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        // quiet for a few pumps in a row: a landed form starts its pile's bake on the next build
        var quiet = 0;
        for (var i = 0; i < 600 && quiet < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          quiet = BotAvatarBakery.instance.pending ? 0 : quiet + 1;
        }
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await _png(await boundary.toImage(pixelRatio: 2), 'widget_$bgName');
      });
    }

    await tester.runAsync(() async {
      /* every type, both materials, author palette, still pose */
      for (final shading in [BotAvatarShading.fabric, BotAvatarShading.plastic]) {
        for (final t in BotAvatarType.values) {
          final p = t.preset;
          final look = BotAvatarLook(
            type: t,
            color: bodyColor(p.color, brightness: p.brightness ?? 1, saturation: p.saturation ?? 1.5),
            shading: shading,
            vivid: (p.saturation ?? 1.5).clamp(1.5, 2.5) - 1.5,
          );
          await _warm(look, 96, 2);
          final rs = BotAvatarRenderState();
          await _png(
            await _frame(look, BotAvatarPose.rest(BotAvatarState.idle), rs, 96, light),
            'type_${shading.name}_${t.name}',
          );
          rs.dispose();
        }
      }
      /* motion: a working clover and an idle star over time, light and dark */
      for (final (name, type, state, shading) in [
        ('working_fabric', BotAvatarType.clover, BotAvatarState.working, BotAvatarShading.fabric),
        ('working_plastic', BotAvatarType.cat, BotAvatarState.working, BotAvatarShading.plastic),
        ('idle_fabric', BotAvatarType.star, BotAvatarState.idle, BotAvatarShading.fabric),
        ('sleeping_fabric', BotAvatarType.ghost, BotAvatarState.sleeping, BotAvatarShading.fabric),
      ]) {
        for (final (bgName, bg) in [('light', light), ('dark', dark)]) {
          final p = type.preset;
          final look = BotAvatarLook(
            type: type,
            color: bodyColor(p.color, brightness: p.brightness ?? 1, saturation: p.saturation ?? 1.5),
            shading: shading,
            vivid: (p.saturation ?? 1.5).clamp(1.5, 2.5) - 1.5,
          );
          await _warm(look, 120, 2);
          final sim = BotAvatarSim(0.37, state);
          final rs = BotAvatarRenderState();
          for (var f = 0; f < 72; f++) {
            for (var s = 0; s < 3; s++) {
              sim.update(1 / 72);
            }
            await _png(await _frame(look, sim.pose, rs, 120, bg), '${name}_${bgName}_${f.toString().padLeft(3, '0')}');
          }
          rs.dispose();
        }
      }
    });
  });
}
