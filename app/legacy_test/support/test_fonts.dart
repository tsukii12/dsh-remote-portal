// Real fonts for widget tests, loaded once per test file by
// `test/flutter_test_config.dart`: goldens show the glyphs a phone shows and
// geometry tests measure real text.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Noto Sans CJK as the tests' CJK fallback. It is also the last entry of
/// `AppType.monoFallback`, so Chinese inside code picks it up too.
const cjkFamily = 'Noto Sans CJK SC';

/// The family Material's Android typography asks for. On a phone it is the
/// system sans; here Noto Sans CJK stands in for it.
const sansFamily = 'Roboto';

bool _loaded = false;

/// Loads the app icons (DshIcons), Material Icons, JetBrains Mono and Noto Sans
/// CJK. Strict: a missing font fails the run rather than quietly drawing the
/// test engine's boxes.
Future<void> loadTestFonts() async {
  if (_loaded) return;
  _loaded = true;
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final material = '$flutterRoot/bin/cache/artifacts/material_fonts';

  Future<void> family(String name, List<String> paths) async {
    final loader = FontLoader(name);
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError('Test font missing: $path');
      }
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await family('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  await family('DshIcons', ['assets/fonts/DshIcons.ttf']);
  await family('JetBrainsMono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-Medium.ttf',
    'assets/fonts/JetBrainsMono-Bold.ttf',
    'assets/fonts/JetBrainsMono-Italic.ttf',
  ]);
  final fontDir = Platform.environment['DSH_TEST_FONT_DIR'] ?? '/usr/share/fonts/noto-cjk';
  final cjk = ['$fontDir/NotoSansCJK-Regular.ttc', '$fontDir/NotoSansCJK-Bold.ttc'];
  // The display sizes are w300: the light face, as on ROMs whose system sans
  // has one.
  final sans = ['$fontDir/NotoSansCJK-Light.ttc', ...cjk];
  await family(sansFamily, sans);
  await family(cjkFamily, sans);
  // `AppType.mono` falls back through `monospace` and `Noto Sans Mono CJK SC`
  // before Noto Sans CJK; the test engine answers an unknown family with its
  // box font for part of CJK. Give those names real glyphs too.
  await family('monospace', cjk);
  await family('Noto Sans Mono CJK SC', cjk);
}

/// [theme] with a family named on every component text style built from the
/// bare type ladder (buttons, chips, dialogs, snack bars, menus, list tiles,
/// tooltips, bars, tabs). A phone resolves a missing family to the system
/// sans; the test engine to its box font. Metrics are unchanged.
ThemeData withTestFonts(ThemeData theme) {
  TextStyle? named(TextStyle? style) => style?.fontFamily != null ? style : style?.copyWith(fontFamily: sansFamily);

  ButtonStyle? button(ButtonStyle? style) {
    final text = style?.textStyle;
    if (style == null || text == null) return style;
    return style.copyWith(textStyle: WidgetStateProperty.resolveWith((states) => named(text.resolve(states))));
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: button(theme.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button(theme.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: button(theme.textButtonTheme.style)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: button(theme.elevatedButtonTheme.style)),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: named(theme.chipTheme.labelStyle),
      secondaryLabelStyle: named(theme.chipTheme.secondaryLabelStyle),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: named(theme.dialogTheme.titleTextStyle),
      contentTextStyle: named(theme.dialogTheme.contentTextStyle),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(contentTextStyle: named(theme.snackBarTheme.contentTextStyle)),
    popupMenuTheme: theme.popupMenuTheme.copyWith(textStyle: named(theme.popupMenuTheme.textStyle)),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: named(theme.listTileTheme.titleTextStyle),
      subtitleTextStyle: named(theme.listTileTheme.subtitleTextStyle),
    ),
    tooltipTheme: theme.tooltipTheme.copyWith(textStyle: named(theme.tooltipTheme.textStyle)),
    appBarTheme: theme.appBarTheme.copyWith(titleTextStyle: named(theme.appBarTheme.titleTextStyle)),
    tabBarTheme: theme.tabBarTheme.copyWith(
      labelStyle: named(theme.tabBarTheme.labelStyle),
      unselectedLabelStyle: named(theme.tabBarTheme.unselectedLabelStyle),
    ),
  );
}
