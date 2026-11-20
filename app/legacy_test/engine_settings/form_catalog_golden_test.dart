// Opt-in only. Owner uses complete product fonts/icons and generates baselines:
// flutter test --dart-define=W3_GOLDENS=true --update-goldens \
//   test/engine_settings/form_catalog_golden_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show loadGoldenFonts;
import 'form_catalog_scenarios.dart';

void main() {
  for (final scene in formCatalogScenes) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.3, 2.0]) {
        testWidgets('golden ${scene.name} 320dp ${brightness.name} ${scale}x', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          await pumpCatalogScene(tester, scene, brightness: brightness, scale: scale);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/w3_${scene.name}_${brightness.name}_${scale}x.png'),
          );
        }, skip: !const bool.fromEnvironment('W3_GOLDENS'));
      }
    }
  }
}
