import 'dart:convert';

import 'package:dsh_app/ui/common/ui_trace.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  testWidgets('the opt-in no-blur probe uses the existing glass fallback', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: GlassSurface(tier: GlassTier.chrome, child: SizedBox(width: 100, height: 100)),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), uiTraceNoBlur ? findsNothing : findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI diagnostics are opt-in and preserve real scrolling without recording text', (tester) async {
    usePhoneView(tester);
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = original);
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: UiTrace(
              scope: 'test',
              child: ListView(
                controller: controller,
                children: const [SizedBox(height: 2000, child: Text('PRIVATE_MESSAGE_MUST_NOT_BE_LOGGED'))],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await pumpFrames(tester);
      expect(controller.offset, greaterThan(0));
      final trace = lines.where((line) => line.startsWith('[DSH_UI] ')).toList();
      if (!uiTraceEnabled) {
        expect(trace, isEmpty);
        return;
      }
      final events = trace
          .map((line) => jsonDecode(line.substring('[DSH_UI] '.length)) as Map<String, dynamic>)
          .toList();
      expect(events.any((event) => event['event'] == 'layout'), isTrue);
      expect(events.any((event) => event['event'] == 'pointer-down'), isTrue);
      expect(events.any((event) => event['event'] == 'pointer-up'), isTrue);
      expect(events.any((event) => event['event'] == 'ScrollUpdateNotification' && event['pixels'] > 0), isTrue);
      expect(trace.join(), isNot(contains('PRIVATE_MESSAGE_MUST_NOT_BE_LOGGED')));
      expect(events.every((event) => event['scope'] == 'test' && event['time'] is int), isTrue);
    } finally {
      debugPrint = original;
    }
  });

  test('non-finite geometry cannot throw from diagnostic serialization', () {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = original);
    expect(() => uiTrace('test', 'unbounded', {'height': double.infinity}), returnsNormally);
    if (uiTraceEnabled) {
      expect(jsonDecode(lines.single.substring('[DSH_UI] '.length))['height'], isNull);
    } else {
      expect(lines, isEmpty);
    }
  });
}
