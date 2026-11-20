// A small harness for plugin-view widget tests: themed MaterialApp, phone
// view, real fonts. Kept apart from test/chat/support/harness.dart so these
// tests only compile what plugin views use.

import 'dart:convert';

import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_fonts.dart';

export '../../support/test_fonts.dart' show cjkFamily, loadTestFonts;

ThemeData testTheme(Brightness brightness) {
  final base = brightness == Brightness.dark ? buildDarkTheme() : buildLightTheme();
  return withTestFonts(base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const [cjkFamily])));
}

/// Phone-sized view (390 × 844 logical, dpr 2).
void usePhoneView(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
}

Widget testApp(Widget home, {Brightness brightness = Brightness.light}) {
  return ProviderScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme(Brightness.light),
      darkTheme: testTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MirroredSideInsets(child: child!),
      home: home,
    ),
  );
}

Future<void> pumpFrames(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ToolChatItem tool(
  String id,
  String name,
  Map<String, Object?> args, {
  ToolStatus status = ToolStatus.succeeded,
  String result = '',
  Object? meta,
}) => ToolChatItem(
  callId: id,
  name: name,
  arguments: jsonEncode(args),
  status: status,
  resultParts: result.isEmpty ? const [] : [TextPart(result)],
  meta: meta,
);
