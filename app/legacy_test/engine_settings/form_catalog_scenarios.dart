// Real schemastery factory outputs; visual tests never execute schema callbacks.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart' show SchemaFieldTile;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class FormCatalogScene {
  const FormCatalogScene(this.name, this.kind, {this.value, this.open = false, this.plugin = false});
  final String name;
  final String kind;
  final Object? value;
  final bool open;
  final bool plugin;
}

const formCatalogScenes = [
  FormCatalogScene('natural', 'number', value: 2, open: true),
  FormCatalogScene('text', 'text', value: 'Voice input', open: true),
  FormCatalogScene('fixed', 'hidden', value: 'fixed'),
  FormCatalogScene('choice', 'choice', value: 'auto'),
  FormCatalogScene('object', 'group', value: {'enabled': true}),
  FormCatalogScene('intersection', 'group', value: {'enabled': true, 'mode': 'local'}),
  FormCatalogScene('strings', 'list', value: ['voice', 'assistant'], open: true),
  FormCatalogScene('numbers', 'list', value: [1, 2], open: true),
  FormCatalogScene('mapping', 'dict', value: {'language': 'zh', 'voice': 'default'}, open: true),
  FormCatalogScene(
    'table',
    'objectList',
    value: [
      {'name': 'Voice route', 'enabled': true},
    ],
    open: true,
  ),
  FormCatalogScene('tuple', 'sequence', value: ['voice', 2, true], open: true),
  FormCatalogScene('toggles', 'sequence', value: [true, false], open: true),
  FormCatalogScene('bits', 'bitset', value: 3, open: true),
  FormCatalogScene('data', 'jsonValue', value: {'language': 'zh', 'enabled': true}, open: true),
  FormCatalogScene('transformed', 'text', value: 'Line one\nLine two', open: true),
  FormCatalogScene('lazy', 'group', value: {'active': true}),
  FormCatalogScene('paragraph', 'text', value: 'First line\n第二行说明', open: true),
  FormCatalogScene('password', 'secret', open: true),
  FormCatalogScene('homepage', 'text', value: 'https://example.test/voice', open: true),
  FormCatalogScene('tint', 'text', value: '#336699', open: true),
  FormCatalogScene('opacity', 'number', value: .5, open: true),
  FormCatalogScene('radio', 'choice', value: 'auto'),
  FormCatalogScene('timestamp', 'text', value: '2026-10-27T12:00:00Z', open: true),
  FormCatalogScene('matcher', 'text', value: '^voice', open: true),
  FormCatalogScene('disabled', 'toggle', value: false),
  FormCatalogScene('hidden', 'hidden'),
  FormCatalogScene('credential', 'hidden'),
  FormCatalogScene('collapsed', 'group', value: {'active': true}),
  FormCatalogScene('callable', 'readOnly'),
  FormCatalogScene('instance', 'readOnly'),
  FormCatalogScene('impossible', 'readOnly'),
  FormCatalogScene('binary', 'readOnly'),
  FormCatalogScene('dsh-ears-0.4.3', 'plugin', plugin: true),
  FormCatalogScene('goodandready-dsh-voice-0.9.42', 'plugin', plugin: true),
  FormCatalogScene('official-speech-to-text-0.2.1-rc.2', 'plugin', plugin: true),
];

Object catalogFixture(String name) => jsonDecode(File('test/engine_settings/fixtures/$name.json').readAsStringSync());

Future<void> pumpCatalogScene(
  WidgetTester tester,
  FormCatalogScene scene, {
  required Brightness brightness,
  required double scale,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 900);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final schema = catalogFixture(scene.plugin ? scene.name : 'schemastery-form-catalog') as Map<String, dynamic>;
  if (!scene.plugin) {
    final node = SchemaNode.fromJson(schema).fields![scene.name]!;
    expect(kindOf(node).name, scene.kind, reason: scene.name);
    final root = (schema['refs'] as Map)['${schema['uid']}'] as Map;
    final dict = root['dict'] as Map;
    root['dict'] = {scene.name: dict[scene.name], 'visible': dict['visible']};
  }
  final base = scene.plugin ? <String, Object?>{} : {scene.name: scene.value, 'visible': true};
  final host = FakeSettingsHost(
    describe: {
      'namespaces': [
        {'ns': 'catalog', 'schema': schema, 'base': base, 'value': base, 'revision': 0},
      ],
    },
  );
  await tester.pumpWidget(
    goldenApp(
      brightness: brightness,
      overrides: engineOverrides(DshClient.withCarrier(host)),
      home: EngineSettingsPage(ns: 'catalog', title: scene.plugin ? scene.name : '插件配置'),
    ),
  );
  await settle(tester);
  expect(
    find.byType(SchemaFieldTile),
    findsWidgets,
    reason: '${scene.name} must finish loading its real form before layout assertions',
  );
  if (scene.plugin) {
    expect(find.byWidgetPredicate((widget) => widget.runtimeType.toString() == 'SchemaFieldTile'), findsWidgets);
    expect(find.text('在网页版编辑此项'), findsNothing);
  } else if (scene.kind == 'hidden') {
    expect(find.byKey(ValueKey('catalog\u0000${scene.name}')), findsNothing);
    expect(find.byType(Switch), findsOneWidget);
  } else if (scene.kind == 'readOnly') {
    expect(find.text('在网页版编辑此项'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget, reason: 'unsupported item cannot replace the whole page');
  } else {
    expect(find.text('在网页版编辑此项'), findsNothing);
  }
  if (scene.open) {
    await tester.tap(find.byKey(ValueKey('catalog\u0000${scene.name}')));
    await settle(tester);
    expect(find.byType(FieldSheetFrame), findsOneWidget);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(FieldSheetFrame))).scale(10),
      closeTo(10 * scale, .001),
      reason: 'the modal route must inherit the scale too',
    );
  }
  expect(tester.takeException(), isNull);
}
