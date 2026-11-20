// New baselines are generated locally by the maintainer. Existing v1 golden
// files and tests are unchanged; compare them with the same fonts/toolchain.
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'style_fixtures.dart';
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final brightness in Brightness.values) {
    for (final (width, scale, suffix) in [(390.0, 1.0, 'phone'), (320.0, 2.0, 'narrow_large')]) {
      testWidgets('v2 style gallery ${brightness.name} $suffix', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = Size(width * 2, (scale == 1 ? 1200 : 2200) * 2);
        await tester.pumpWidget(
          testApp(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: PluginView(view: styleGallery, onAction: (_) async => true),
                ),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/plugin_view_styles_${brightness.name}_$suffix.png'),
        );
      });
    }
  }
}
