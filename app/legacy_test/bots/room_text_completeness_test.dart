import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
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
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_truncated_post.json').readAsStringSync()) as Map;
  final full = {
    'text': ((fixture['unit'] as String) * (fixture['inputRepeats'] as int)).substring(0, fixture['textLength'] as int),
    'whole': fixture['whole'],
  };
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

  testWidgets('actual truncated response shows prefix notice and exact returned text', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => full;
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(hasText(t), isTrue);
    expect(find.text('仅显示前 200,000 个字符'), findsOneWidget);
    expect(old.endpoints.where((e) => e == 'file-text'), hasLength(1));
    expect(t.takeException(), isNull);
  });
  testWidgets('partial notice lines up with the text, equal insets either side', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => full;
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    final width = t.view.physicalSize.width / t.view.devicePixelRatio;
    final notice = t.getRect(find.byKey(const ValueKey('bot-file-text-completeness')));
    final body = t.getRect(find.byType(MarkdownBody).last);
    expect(notice.left, moreOrLessEquals(body.left, epsilon: 0.01));
    expect(notice.right, moreOrLessEquals(body.right, epsilon: 0.01));
    expect(notice.left, moreOrLessEquals(width - notice.right, epsilon: 0.01));
    expect(notice.bottom, lessThan(body.top));
  });
  testWidgets('actual complete response has no partial or unknown warning', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => fixture['complete'];
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(find.byKey(const ValueKey('bot-file-text-completeness')), findsNothing);
    expect(
      t.widgetList<MarkdownBody>(find.byType(MarkdownBody)).any((w) => w.text == fixture['complete']['text']),
      isTrue,
    );
  });
  for (final value in [
    {'text': 'synthetic'},
    {'text': 'synthetic', 'whole': 'true'},
    'legacy synthetic',
  ]) {
    testWidgets('unknown completeness is visible for $value', (t) async {
      final old = fake();
      old.handlers['file-text'] = (_) => value;
      await open(t, old, fake());
      await t.tap(find.text('显示全部'));
      await frames(t);
      expect(find.text('无法确认是否为完整内容'), findsOneWidget);
    });
  }
  testWidgets('malformed text shows read failure instead of blank complete content', (t) async {
    final old = fake();
    old.handlers['file-text'] = (_) => {'whole': true};
    await open(t, old, fake());
    await t.tap(find.text('显示全部'));
    await frames(t);
    expect(find.text('出了点问题'), findsOneWidget);
    expect(find.text('全文'), findsNothing);
  });
  for (final brightness in Brightness.values) {
    testWidgets('partial notice 320dp 2x ${brightness.name}', (t) async {
      final old = fake();
      old.handlers['file-text'] = (_) => {'text': '合成预览', 'whole': false};
      await open(t, old, fake(), scale: 2, brightness: brightness);
      await t.tap(find.text('显示全部'));
      await frames(t);
      expect(find.text('仅显示前 4 个字符'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
    testWidgets('partial notice golden ${brightness.name}', (t) async {
      final old = fake();
      old.handlers['file-text'] = (_) => {'text': '合成预览', 'whole': false};
      await open(t, old, fake(), brightness: brightness);
      await t.tap(find.text('显示全部'));
      await frames(t);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/room_text_partial_${brightness.name}.png'),
      );
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}
