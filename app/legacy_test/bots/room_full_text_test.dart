import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/features/feature_widgets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef value) => state = value;
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_long_post.json').readAsStringSync()) as Map;
  final full = (fixture['full']['value'] as Map).cast<String, Object?>();
  final retired = find.byKey(const ValueKey('room-full-text-retired'));
  bool hasText(WidgetTester t) =>
      t.widgetList<MarkdownBody>(find.byType(MarkdownBody)).any((w) => w.text == full['text']);
  FakeDsBotTransport fake() => FakeDsBotTransport(team: sampleTeam(working: false))
    ..helloOnFeed = false
    ..roomItems = List<Object?>.from(fixture['projected']);
  Future<ProviderContainer> open(
    WidgetTester t,
    FakeDsBotTransport old,
    FakeDsBotTransport next, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    usePhoneView(t);
    t.view.physicalSize = const Size(640, 1688);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      goldenApp(
        brightness: brightness,
        home: const RoomChatPage(roomId: 'r1'),
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWith((ref) {
            final h = ref.watch(activeHostProvider);
            return AsyncData(
              HostConnection(
                client: fakeConnection.client,
                label: h.id,
                isLocal: h.isLocal,
                kind: h.kind,
                hostId: h.id,
              ),
            );
          }),
          dsBotApiFactoryProvider.overrideWithValue((c) => DsBotApi((c.hostId == HostRef.none.id) ? old : next)),
        ],
      ),
    );
    await frames(t);
    return ProviderScope.containerOf(t.element(find.byType(RoomChatPage)));
  }

  for (final change in ['host', 'aba', 'reconnect', 'boot', 'removed', 'dispose']) {
    for (final failure in [false, true]) {
      testWidgets('full-text old ${failure ? 'error' : 'success'} after $change is retired', (t) async {
        final old = fake(), next = fake();
        final pending = Completer<Object?>();
        old.handlers['file-text'] = (_) => pending.future;
        final c = await open(t, old, next);
        await t.tap(find.text('显示全部'));
        await frames(t);
        expect(old.endpoints.where((e) => e == 'file-text'), hasLength(1));
        if (change == 'host' || change == 'aba') {
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
          await frames(t);
          if (change == 'aba') {
            c.read(activeHostProvider.notifier).select(HostRef.none);
            await frames(t);
          }
        } else if (change == 'reconnect') {
          c.read(dsBotProvider.notifier).retry();
          await frames(t);
        } else if (change == 'boot') {
          old.emit('hello', {'boot': 'restarted', 'seq': 0});
          await frames(t);
        } else if (change == 'removed') {
          old.handlers['state'] = (_) => {...sampleTeam(working: false), 'rooms': []};
          await c.read(dsBotProvider.notifier).refresh();
          await frames(t);
        } else {
          await t.pumpWidget(const SizedBox.shrink());
          await frames(t);
        }
        if (failure) {
          pending.completeError(const DshTransportException('old file failed'));
        } else {
          pending.complete(full);
        }
        await frames(t);
        expect(hasText(t), isFalse);
        expect(find.byType(SnackBar), findsNothing);
        expect(t.takeException(), isNull);
        if (change != 'dispose') expect(retired, findsOneWidget);
      });
    }
  }
  testWidgets('current target opens actual full text once and closing retires pending reads', (t) async {
    final old = fake();
    final pending = Completer<Object?>();
    old.handlers['file-text'] = (_) => pending.future;
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await t.tap(find.text('显示全部'), warnIfMissed: false);
    await frames(t);
    expect(old.endpoints.where((e) => e == 'file-text'), hasLength(1));
    Navigator.of(t.element(find.byType(RoomChatPage))).pop();
    await frames(t);
    pending.complete(full);
    await frames(t);
    expect(hasText(t), isFalse);
    expect(t.takeException(), isNull);
  });
  testWidgets('same target success preserves actual UTF8 file content', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => full;
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(hasText(t), isTrue);
    expect(retired, findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('current failure stays in its sheet and retry can read successfully', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => throw const DshTransportException('read failed');
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    old.handlers['file-text'] = (_) => full;
    await t.tap(find.text('重试'));
    await frames(t);
    expect(hasText(t), isTrue);
    expect(old.endpoints.where((e) => e == 'file-text'), hasLength(2));
  });
  testWidgets('read failure and changed conversation sit centred, equal insets either side', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => throw const DshTransportException('read failed');
    final c = await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    final width = t.view.physicalSize.width / t.view.devicePixelRatio;
    void centred(Finder f) {
      final r = t.getRect(f);
      expect(r.left, moreOrLessEquals(width - r.right, epsilon: 0.01), reason: '$f');
    }

    centred(find.byType(FeatureMessage));
    centred(find.text('没能读取全文'));
    centred(find.text('重试'));
    c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
    await frames(t);
    centred(find.byKey(const ValueKey('room-full-text-retired')));
    centred(find.text('对话已变化'));
    centred(find.text('请重新打开这条消息'));
    expect(t.takeException(), isNull);
  });
  testWidgets('already visible text is withdrawn when host changes', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => full;
    final c = await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(hasText(t), isTrue);
    c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
    await frames(t);
    expect(hasText(t), isFalse);
    expect(retired, findsOneWidget);
  });
  testWidgets('readonly does not unnecessarily block current read', (t) async {
    final old = fake();
    old.handlers['state'] = (_) => {...sampleTeam(working: false), 'readOnly': 'other owner'};
    old.handlers['file-text'] = (_) => full;
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(hasText(t), isTrue);
  });
  for (final brightness in Brightness.values) {
    testWidgets('full text 320dp 2x ${brightness.name}', (t) async {
      final old = fake();
      old.handlers['file-text'] = (_) => full;
      await open(t, old, fake(), scale: 2, brightness: brightness);
      await t.tap(find.text('显示全部'));
      await frames(t);
      expect(hasText(t), isTrue);
      expect(t.takeException(), isNull);
    });
    testWidgets('full text golden ${brightness.name}', (t) async {
      final old = fake();
      old.handlers['file-text'] = (_) => full;
      await open(t, old, fake(), brightness: brightness);
      await t.tap(find.text('显示全部'));
      await frames(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/room_full_text_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}
