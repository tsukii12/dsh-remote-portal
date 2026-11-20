import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import '../shell/golden_harness.dart' show goldenApp;

Object fixture(String name) => jsonDecode(File('test/engine_settings/fixtures/$name.json').readAsStringSync());

FakeSettingsHost schemaHost(Object schema, {Map<String, Object?> base = const {}}) => FakeSettingsHost(
  describe: {
    'namespaces': [
      {'ns': 'structure', 'schema': schema, 'value': base, 'base': base, 'revision': 0},
    ],
  },
);

void main() {
  testWidgets('local fallback keeps its supported sibling interactive', (tester) async {
    final host = schemaHost(
      {
        'type': 'intersect',
        'list': [
          {
            'type': 'object',
            'dict': {
              'enabled': {'type': 'boolean'},
            },
          },
          {'type': 'unknown-extension'},
        ],
      },
      base: {'enabled': false},
    );
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'structure'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    expect(find.byType(SchemaUnsupportedField), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await flush(tester);
    expect(host.mutates().single['ops'], [
      {
        'op': 'set',
        'path': ['enabled'],
        'value': true,
      },
    ]);
  });

  testWidgets('disabled parent keeps nested toggle disabled', (tester) async {
    final host = schemaHost({
      'type': 'object',
      'dict': {
        'locked': {
          'type': 'object',
          'meta': {'disabled': true},
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
      },
    });
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'structure'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(host.mutates(), isEmpty);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('real voice schema narrow ${brightness.name} $scale', (tester) async {
        final host = schemaHost(fixture('dsh-ears-0.4.3'));
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.reset);
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
        expect(find.byType(SchemaUnsupportedField), findsNothing);
        expect(find.byType(SchemaFieldTile), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
