// Opt-in developer preview. Ordinary test runs skip it; it never reads or writes
// a golden baseline. Invoke through sdk/plugin-kit/bin/preview.mjs.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final path = Platform.environment['DSH_PLUGIN_PREVIEW_REQUEST'];
  if (path == null) {
    testWidgets('local plugin preview (opt-in)', (_) async {}, skip: true);
    return;
  }
  final file = File(path);
  final request = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final budget = PluginViewBudget.values.byName(request['budget'] as String);
  final width = (request['width'] as num).toDouble();
  final height = (request['height'] as num).toDouble();
  final scale = (request['scale'] as num).toDouble();
  final locale = request['lang'] == 'en' ? AppLocale.en : AppLocale.zhCN;

  for (final theme in request['themes'] as List) {
    testWidgets('local plugin preview $theme', (tester) async {
      AppLocale.use(locale);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.reset);
      final brightness = theme == 'dark' ? Brightness.dark : Brightness.light;
      final boundary = GlobalKey();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final parsed = parsePluginView(request['view'], data: request['data'], budget: budget);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: locale,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: boundary,
                  child: Scaffold(
                    body: AppBackdrop(
                      child: SingleChildScrollView(
                        controller: scroll,
                        padding: const EdgeInsets.all(16),
                        child: PluginFrame(
                          pluginName: locale.languageCode == 'en' ? 'Local preview' : '本地预览',
                          child: PluginView(
                            view: request['view'],
                            data: request['data'],
                            budget: budget,
                            // Show panel affordances without invoking any host.
                            onAction: budget == PluginViewBudget.panel ? (_) async => false : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          brightness: brightness,
        ),
      );
      await tester.pump();
      // Inline image codecs need real async work. No asset resolver or network
      // image source is installed by this preview.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'Preview layout must complete without framework errors');
      final context = tester.element(find.byType(PluginView));
      expect(MediaQuery.textScalerOf(context).scale(10), closeTo(10 * scale, 0.000001));
      expect(Theme.of(context).brightness, brightness);
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) throw StateError('PNG encoding returned no bytes');
          return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
        } finally {
          image.dispose();
        }
      });
      expect(png, isNotNull);
      final out = File('${file.parent.path}/$theme.png');
      if (out.existsSync()) throw StateError('Refusing to overwrite ${out.path}');
      await tester.runAsync(() => out.writeAsBytes(png!, flush: true));
      final issues = switch (parsed) {
        DshUiParsed(:final view) => view.issues,
        DshUiInvalid(:final error) => [error],
      };
      final diagnostic = {
        'renderer': 'App PluginView',
        'theme': theme,
        'locale': locale.toLanguageTag(),
        'budget': budget.name,
        'width': width,
        'height': height,
        'textScale': scale,
        'remainingScrollExtent': scroll.position.maxScrollExtent,
        'viewportOnly': true,
        'hostConnected': false,
        'assetResolverInstalled': false,
        'fatal': parsed is DshUiInvalid,
        'issues': [
          for (final i in issues) {'path': i.path, 'message': i.message},
        ],
      };
      final details = File('${file.parent.path}/$theme.json');
      if (details.existsSync()) throw StateError('Refusing to overwrite ${details.path}');
      await tester.runAsync(() => details.writeAsString('${const JsonEncoder.withIndent('  ').convert(diagnostic)}\n'));
    });
  }
}
