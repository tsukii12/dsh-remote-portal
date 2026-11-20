// The icon system's guard rails: widgets name icons only through AppIcons, the
// generated code-point table matches the font, and a sheet of every glyph in
// light and dark.
//
//   flutter test --update-goldens test/icons/app_icons_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/ui/theme/dsh_glyphs.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The code points a TrueType font maps, from its format 4 cmap subtable.
Set<int> _cmap(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    if (String.fromCharCodes(bytes.sublist(record, record + 4)) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  expect(cmap, isNot(-1), reason: 'no cmap table');
  final out = <int>{};
  for (var i = 0; i < data.getUint16(cmap + 2); i++) {
    final sub = cmap + data.getUint32(cmap + 4 + 8 * i + 4);
    if (data.getUint16(sub) != 4) continue;
    final segs = data.getUint16(sub + 6) ~/ 2;
    final ends = sub + 14;
    final starts = ends + 2 * segs + 2;
    for (var s = 0; s < segs; s++) {
      final start = data.getUint16(starts + 2 * s);
      final end = data.getUint16(ends + 2 * s);
      if (start == 0xFFFF) continue;
      for (var c = start; c <= end; c++) {
        out.add(c);
      }
    }
  }
  return out;
}

void main() {
  test('widgets name icons through AppIcons, never Icons.*', () {
    final offenders = <String>[];
    final use = RegExp(r'\bIcons\.[a-zA-Z_]');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (use.hasMatch(lines[i])) offenders.add('$path:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty, reason: 'Use an AppIcons role (lib/ui/theme/app_icons.dart); add one if none fits.');
  });

  test('every role maps to a glyph the font carries', () {
    final roles = RegExp(
      r'^  static const (\w+) = DshGlyphs\.(\w+);',
      multiLine: true,
    ).allMatches(File('lib/ui/theme/app_icons.dart').readAsStringSync()).map((m) => (m[1]!, m[2]!)).toList();
    expect(roles, isNotEmpty);
    final carried = _cmap(File('assets/fonts/DshIcons.ttf').readAsBytesSync());
    for (final (role, glyph) in roles) {
      final data = DshGlyphs.all[glyph];
      expect(data, isNotNull, reason: 'AppIcons.$role: DshGlyphs.$glyph missing; run tool/make_icon_font.py');
      expect(data!.fontFamily, 'DshIcons');
      expect(data.fontPackage, isNull);
      expect(carried, contains(data.codePoint), reason: 'DshIcons.ttf lacks $glyph; run tool/make_icon_font.py');
    }
    // Nothing the tokens dropped lingers in the table.
    expect(DshGlyphs.all.keys.toSet(), roles.map((r) => r.$2).toSet());
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('glyph sheet ($mode)', (tester) async {
      const columns = 12;
      const cell = Size(64, 60);
      final glyphs = DshGlyphs.all.entries.toList();
      final rows = (glyphs.length / columns).ceil();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(columns * cell.width * 2, (rows * cell.height + 16) * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme(),
          home: Builder(
            builder: (context) {
              final colors = DshColors.of(context);
              return Material(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    children: [
                      for (final MapEntry(:key, :value) in glyphs)
                        SizedBox.fromSize(
                          size: cell,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(value, size: 24, color: Theme.of(context).colorScheme.onSurface),
                              const SizedBox(height: 6),
                              Text(
                                key,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 7, color: colors.textTertiary),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/glyph_sheet_$mode.png'));
    });
  }
}
