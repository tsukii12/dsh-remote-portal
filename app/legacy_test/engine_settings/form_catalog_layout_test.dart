import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'form_catalog_scenarios.dart';

void main() {
  for (final scene in formCatalogScenes) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.3, 2.0]) {
        testWidgets('${scene.name} 320dp ${brightness.name} ${scale}x', (tester) async {
          await pumpCatalogScene(tester, scene, brightness: brightness, scale: scale);
        });
      }
    }
  }
}
