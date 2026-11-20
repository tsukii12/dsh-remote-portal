// Shared setup for the feature-tile tests: a themed app on the real page
// backdrop, and a helper that finishes decoding the glass bitmaps.

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

ThemeData tileTheme(Brightness brightness, [AppAccent accent = AppAccent.mist]) {
  final base = brightness == Brightness.dark ? buildDarkTheme(accent: accent) : buildLightTheme(accent: accent);
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

Widget tileApp(Widget child, {Brightness brightness = Brightness.light, List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: tileTheme(brightness),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AppBackdrop(child: child),
    ),
  );
}

/// Sets a [width] × [height] logical view at dpr 2.
void useView(WidgetTester tester, double width, double height) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  addTearDown(tester.view.reset);
}

/// Decodes every [Image] on screen for real (the test clock doesn't run codecs),
/// then pumps a frame.
Future<void> decodeImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pump();
}
