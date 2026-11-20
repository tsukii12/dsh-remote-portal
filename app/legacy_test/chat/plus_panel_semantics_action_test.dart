import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> _open(WidgetTester tester, ValueChanged<PlusChoice?> onChoice) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => onChoice(await showPlusPanel(context, generate: true)),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await pumpFrames(tester);
}

void main() {
  setUpAll(loadTestFonts);

  for (final (label, source) in <(String, AttachSource?)>[
    ('相册', AttachSource.gallery),
    ('拍照', AttachSource.camera),
    ('文件', AttachSource.files),
    ('生成', null),
  ]) {
    testWidgets('$label semantic tap returns its choice and closes the panel', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        PlusChoice? choice;
        await _open(tester, (value) => choice = value);
        final node = tester.getSemantics(find.widgetWithText(PlusTile, label));
        final data = node.getSemanticsData();
        expect(data.label, label);
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);

        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        await pumpFrames(tester);
        expect(find.byType(PlusTile), findsNothing);
        if (source == null) {
          expect(choice, isA<GenerateChoice>());
        } else {
          expect(choice, isA<AttachChoice>().having((value) => value.source, 'source', source));
        }
      } finally {
        handle.dispose();
      }
    });
  }

  testWidgets('a physical tap still returns generation and closes the panel', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      PlusChoice? choice;
      await _open(tester, (value) => choice = value);
      await tester.tap(find.widgetWithText(PlusTile, '生成'));
      await pumpFrames(tester);
      expect(find.byType(PlusTile), findsNothing);
      expect(choice, isA<GenerateChoice>());
    } finally {
      handle.dispose();
    }
  });
}
