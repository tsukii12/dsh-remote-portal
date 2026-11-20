import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

enum _Exit { save, submit, cancel, back }

class _RenameHost extends DrawerHost {
  bool rejectRename = false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'session/rename') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    if (rejectRename) return const RpcError(DshRemoteException('RENAME_REFUSED', 'rename refused'));
    final request = args['request']! as Map;
    final row = sessions.singleWhere((session) => session['sessionId'] == request['sessionId']);
    row['projections'] = {
      'kind': 'hints',
      'asOfSeq': 2,
      'values': {'title': request['title']},
    };
    return RpcOk({'title': request['title']});
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

Finder get _field => find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

Future<(_RenameHost, ModalRoute<Object?>)> _openRename(WidgetTester tester, {bool fluid = false}) async {
  final host = _RenameHost()..seedSession('s1', '原对话', sampleNow);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      animations: true,
      overrides: workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: 's1'),
      home: AppMotionScope(
        fluid: fluid,
        child: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      ),
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  await tester.longPress(find.widgetWithText(SessionTile, '原对话'));
  await _settle(tester);
  await tester.tap(find.text('重命名'));
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1));

  final field = tester.widget<TextField>(_field);
  expect(field.controller!.text, '原对话');
  expect(field.maxLength, 80);
  expect(field.decoration!.counterText, '');
  expect(field.autofocus, isTrue);
  expect(field.obscureText, isFalse);
  expect(field.enableSuggestions, isTrue);
  final editable = tester.widget<EditableText>(find.descendant(of: _field, matching: find.byType(EditableText)));
  expect(editable.focusNode.hasFocus, isTrue);
  final route = ModalRoute.of<Object?>(tester.element(find.byType(AlertDialog)))!;
  expect(route.animation!.status, AnimationStatus.completed);
  if (fluid) expect(route.transitionDuration, AppMotion.popCurve.duration);
  expect(route.reverseTransitionDuration, greaterThan(Duration.zero));
  return (host, route);
}

Future<void> _finishExit(WidgetTester tester, Duration duration) async {
  await tester.pump();
  expect(tester.takeException(), isNull);
  expect(_field, findsOneWidget);
  final frames = (duration.inMilliseconds / 16).ceil() + 2;
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: 'exit frame $frame');
  }
  expect(find.byType(AlertDialog), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final fluid in [false, true]) {
    for (final exit in _Exit.values) {
      testWidgets('drawer rename ${exit.name} survives ${fluid ? "fluid" : "standard"} exit', (tester) async {
        final (host, route) = await _openRename(tester, fluid: fluid);
        await tester.enterText(_field, '  新对话  ');
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
        await _finishExit(tester, route.reverseTransitionDuration);
        final saves = exit == _Exit.save || exit == _Exit.submit;
        expect(await route.popped, saves ? '新对话' : isNull);
        expect(
          host.argsOf('session/rename'),
          saves
              ? [
                  {
                    'request': {'sessionId': 's1', 'title': '新对话'},
                  },
                ]
              : isEmpty,
        );
        expect(find.widgetWithText(SessionTile, saves ? '新对话' : '原对话'), findsOneWidget);
      });
    }
  }

  testWidgets('drawer rename keeps the 80 character field limit', (tester) async {
    final (host, route) = await _openRename(tester);
    await tester.enterText(_field, '名' * 81);
    expect(tester.widget<TextField>(_field).controller!.text, '名' * 80);
    await tester.tap(find.text('保存'));
    await _finishExit(tester, route.reverseTransitionDuration);
    expect(await route.popped, '名' * 80);
    expect(host.argsOf('session/rename'), [
      {
        'request': {'sessionId': 's1', 'title': '名' * 80},
      },
    ]);
  });

  for (final value in ['   ', '  原对话  ']) {
    testWidgets('drawer rename returns trimmed "$value" without a Host write', (tester) async {
      final (host, route) = await _openRename(tester);
      await tester.enterText(_field, value);
      await tester.tap(find.text('保存'));
      await _finishExit(tester, route.reverseTransitionDuration);
      expect(await route.popped, value.trim());
      expect(host.argsOf('session/rename'), isEmpty);
      expect(find.widgetWithText(SessionTile, '原对话'), findsOneWidget);
    });
  }

  testWidgets('drawer rename keeps the Host refusal and old title visible', (tester) async {
    final (host, route) = await _openRename(tester);
    host.rejectRename = true;
    await tester.enterText(_field, '新对话');
    await tester.tap(find.text('保存'));
    await _finishExit(tester, route.reverseTransitionDuration);
    expect(host.argsOf('session/rename'), hasLength(1));
    expect(find.widgetWithText(SessionTile, '原对话'), findsOneWidget);
    expect(find.text('没能重命名，稍后再试'), findsOneWidget);
  });
}
