// Owner generates baselines using the complete product fonts and icons:
// flutter test --dart-define=W3_GOLDENS=true --update-goldens \
//   test/engine_settings/schema_structure_golden_test.dart
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'schema_structure_widgets_test.dart' show fixture, schemaHost;
import 'support.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('voice structure ${brightness.name} $scale', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.reset);
        final host = schemaHost(fixture('dsh-ears-0.4.3'));
        await tester.pumpWidget(
          goldenApp(
            brightness: brightness,
            overrides: engineOverrides(DshClient.withCarrier(host)),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: const EngineSettingsPage(ns: 'structure', title: '语音输入'),
              ),
            ),
          ),
        );
        await flush(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/w3_voice_${brightness.name}_${scale}x.png'),
        );
      }, skip: !const bool.fromEnvironment('W3_GOLDENS'));
    }
  }
}
