import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

enum _Exit { save, submit, cancel, back }

Future<Duration> _openRename(WidgetTester tester, FakeTerminalBackend backend, {bool fluid = false}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      animations: true,
      overrides: terminalOverrides(backend),
      home: AppMotionScope(
        fluid: fluid,
        child: const TerminalPage(sessionId: 's1'),
      ),
    ),
  );
  await settleTerminal(tester);
  await tester.tap(find.byKey(const ValueKey('terminal-more')));
  await settleTerminal(tester);
  await tester.tap(find.text('重命名'));
  await settleTerminal(tester);
  await tester.pump(const Duration(seconds: 1));

  final field = tester.widget<TextField>(find.byType(TextField));
  expect(field.controller!.text, 'build');
  expect(field.maxLength, 120);
  expect(field.decoration!.counterText, '');
  expect(field.autofocus, isTrue);
  expect(field.obscureText, isFalse);
  expect(field.enableSuggestions, isTrue);
  final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
  expect(route.animation!.status, AnimationStatus.completed);
  if (fluid) expect(route.transitionDuration, AppMotion.popCurve.duration);
  expect(route.reverseTransitionDuration, greaterThan(Duration.zero));
  return route.reverseTransitionDuration;
}

Future<void> _finishExit(WidgetTester tester, Duration duration) async {
  await tester.pump();
  expect(tester.takeException(), isNull);
  // The result has been returned, but the field is still in its exit animation.
  expect(find.byType(TextField), findsOneWidget);
  final frames = (duration.inMilliseconds / 16).ceil() + 2;
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: 'exit frame $frame');
  }
  expect(find.byType(AlertDialog), findsNothing);
  expect(find.byType(TextField), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final fluid in [false, true]) {
    for (final exit in _Exit.values) {
      testWidgets('rename ${exit.name} keeps its controller alive through ${fluid ? "fluid" : "standard"} exit', (
        tester,
      ) async {
        final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
        final duration = await _openRename(tester, backend, fluid: fluid);
        await tester.enterText(find.byType(TextField), '  编译终端  ');
        switch (exit) {
          case _Exit.save:
            await tester.tap(find.text('保存'));
          case _Exit.submit:
            await tester.testTextInput.receiveAction(TextInputAction.done);
          case _Exit.cancel:
            await tester.tap(find.text('取消'));
          case _Exit.back:
            await tester.binding.handlePopRoute();
        }
        await _finishExit(tester, duration);
        final saves = exit == _Exit.save || exit == _Exit.submit;
        expect(backend.calls.where((call) => call == 'rename'), hasLength(saves ? 1 : 0));
        expect(backend.host['a']!['title'], saves ? '编译终端' : 'build');
        expect(find.text(saves ? '编译终端' : 'build'), findsOneWidget);
      });
    }
  }

  testWidgets('rename preserves the field length limit before saving', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
    final duration = await _openRename(tester, backend);
    await tester.enterText(find.byType(TextField), '终' * 121);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '终' * 120);
    await tester.tap(find.text('保存'));
    await _finishExit(tester, duration);
    expect(backend.host['a']!['title'], '终' * 120);
    expect(backend.calls.where((call) => call == 'rename'), hasLength(1));
  });

  for (final value in ['   ', '  build  ']) {
    testWidgets('rename returns an empty or unchanged trimmed value without writing: "$value"', (tester) async {
      final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
      final duration = await _openRename(tester, backend);
      await tester.enterText(find.byType(TextField), value);
      await tester.tap(find.text('保存'));
      await _finishExit(tester, duration);
      expect(backend.host['a']!['title'], 'build');
      expect(backend.calls.where((call) => call == 'rename'), isEmpty);
    });
  }
}
