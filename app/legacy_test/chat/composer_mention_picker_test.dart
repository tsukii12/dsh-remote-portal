// The `@` picker on the chat screen: what it lists (files, subagents,
// conversations, recent picks first), filtering as the person types, picking
// by tap / send key / hardware keys, opening folders, and what is sent.
// Goldens: `flutter test --update-goldens test/chat/composer_mention_picker_test.dart`.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/mention_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_chip.dart';
import 'package:dsh_app/ui/chat/mention/mention_picker.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Sessions extends FakeSessions {
  _Sessions(this.list);
  final List<SessionSummary> list;

  @override
  Future<List<SessionSummary>> build() async => list;
}

/// The chat harness with conversations on this phone.
class _Harness extends ChatHarness {
  _Harness(this._sessions, {super.session, super.states, super.settings});
  final _Sessions _sessions;

  @override
  FakeSessions get sessions => _sessions;
}

class _Setup {
  _Setup({String? session = 'main', List<SessionSummary> local = const [], bool enterSends = false})
    : harness = _Harness(
        _Sessions(local),
        session: session,
        states: {?session: const ChatState(loading: false)},
        settings: AppSettings(loaded: true, apiKey: testKey, hardwareEnterSends: enterSends),
      ),
      carrier = referenceHost(now: DateTime.now());

  final ChatHarness harness;
  final FakeRpcCarrier carrier;
  final recents = MentionRecents(persist: false);

  late final client = DshClient.withCarrier(carrier);

  Future<void> pump(WidgetTester tester, {Brightness brightness = Brightness.light, bool enterSends = false}) async {
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        brightness: brightness,
        overrides: [
          ...harness.overrides,
          mentionSourceProvider.overrideWithValue(ClientMentionSource(client)),
          mentionRecentsProvider.overrideWithValue(recents),
          voiceBridgeProvider.overrideWithValue(FakeVoiceBridge(caps: VoiceCapabilities.none)),
        ],
      ),
    );
    await pumpFrames(tester, 8);
  }
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// Past the palette's cross-fade.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

TextEditingController _draft(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!;

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  testWidgets('a bare @: files, then subagents, then conversations', (tester) async {
    final setup = _Setup();
    await setup.pump(tester);
    await _type(tester, '@');

    expect(find.byType(MentionPicker), findsOneWidget);
    expect(find.byType(SlashPalette), findsNothing);
    for (final title in ['文件', '子代理', '对话']) {
      expect(find.text(title), findsOneWidget);
    }
    final files = tester.getRect(find.text('README.md'));
    final subagent = tester.getRect(find.text('检查依赖'));
    final conversation = tester.getRect(find.text('修复登录重复提交'));
    expect(files.top, lessThan(subagent.top));
    expect(subagent.top, lessThan(conversation.top));
    // Another workspace says where it is.
    expect(find.textContaining('notes · '), findsOneWidget);
    expect(find.text('lib/'), findsOneWidget);
    // Discovery runs against the open conversation.
    expect(setup.carrier.argsOf('fileReferences/list').first, {'agentId': 'main', 'query': ''});
    expect(setup.carrier.argsOf('sessionReferenceResolver/candidates').first, {'agentId': 'main', 'query': ''});
  });

  testWidgets('typing filters; sending picks the marked row; then it sends', (tester) async {
    final setup = _Setup();
    await setup.pump(tester);
    await _type(tester, '看看 @mai');
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('README.md'), findsNothing);
    expect(find.text('修复登录重复提交'), findsNothing);

    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);
    final draft = _draft(tester);
    expect(draft.text, '看看 @lib/main.dart ');
    expect(find.byType(MentionChip), findsOneWidget);
    expect(find.byType(MentionPicker), findsNothing);
    expect(setup.harness.controllers['main']!.sent, isEmpty);

    // The rest of the message, then a real send: the wire text goes out.
    draft.value = TextEditingValue(
      text: '${draft.text}为什么报错',
      selection: TextSelection.collapsed(offset: draft.text.length + 4),
    );
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 2);
    expect(setup.harness.controllers['main']!.sent, ['看看 @lib/main.dart 为什么报错']);
  });

  testWidgets('sending a changed query without current results preserves literal sending', (tester) async {
    final setup = _Setup();
    await setup.pump(tester);
    await _type(tester, '@mai');
    expect(find.text('main.dart'), findsOneWidget);

    // Before the new lookup's debounce: the previous row has no authority
    // over this query. As on a first lookup, Send can send the literal text.
    await tester.enterText(find.byType(TextField), '@missing');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 2);
    expect(setup.harness.controllers['main']!.sent, ['@missing']);
    expect(_draft(tester).text, isEmpty);
    expect(setup.recents.entries, isEmpty);
  });

  testWidgets('a conversation goes in as its canonical mention', (tester) async {
    final setup = _Setup();
    await setup.pump(tester);
    await _type(tester, '@修复');
    await tester.tap(find.text('修复登录重复提交'));
    await _settle(tester);
    expect(_draft(tester).text, '${formatSessionMention('login', '修复登录重复提交')} ');
    expect(find.text('修复登录重复提交'), findsOneWidget); // the chip
    // Picked lately: first under 「最近」 on the next bare @.
    await _type(tester, '@');
    expect(find.text('最近'), findsOneWidget);
    final recent = tester.getRect(find.descendant(of: find.byType(MentionPicker), matching: find.text('修复登录重复提交')));
    expect(recent.top, lessThan(tester.getRect(find.text('README.md')).top));
  });

  testWidgets('the › on a folder opens it in the picker', (tester) async {
    final setup = _Setup();
    await setup.pump(tester);
    await _type(tester, '@');
    await tester.tap(find.byIcon(AppIcons.disclosure));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_draft(tester).text, '@lib/');
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('ui/'), findsOneWidget);
    // A path lists files only.
    expect(find.text('对话'), findsNothing);
    // Picking the folder row itself makes a folder chip.
    await tester.tap(find.text('ui/'));
    await _settle(tester);
    expect(_draft(tester).text, '@lib/ui/ ');
    expect(find.byType(MentionChip), findsOneWidget);
  });

  testWidgets('hardware keys: Enter picks before opt-in Enter-to-send, Esc closes', (tester) async {
    final setup = _Setup(enterSends: true);
    await setup.pump(tester);
    await tester.tap(find.byType(TextField));
    await _type(tester, '@d');
    // README.md (marked), lib/main.dart, lib/ui/login page.dart, …
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(_draft(tester).text, '@lib/main.dart ');

    await _type(tester, '@lib/main.dart @');
    expect(find.byType(MentionPicker), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byType(MentionPicker), findsNothing);
  });

  testWidgets('a new chat lists conversations from this phone', (tester) async {
    final now = DateTime.now();
    final setup = _Setup(
      session: null,
      local: [
        SessionSummary(
          sessionId: 'login',
          updatedAt: now.subtract(const Duration(hours: 3)),
          running: false,
          blank: false,
          agentAvailable: false,
          projections: const SessionProjections(1, {'title': '修复登录重复提交'}),
        ),
      ],
    );
    await setup.pump(tester);
    await _type(tester, '@');
    expect(find.text('修复登录重复提交'), findsOneWidget);
    expect(find.text('3小时'), findsOneWidget);
    expect(find.text('文件'), findsNothing);
    expect(setup.carrier.calls, isEmpty);
    await tester.tap(find.text('修复登录重复提交'));
    await _settle(tester);
    expect(_draft(tester).text, '${formatSessionMention('login', '修复登录重复提交')} ');
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: picker over the chat (${brightness.name})', (tester) async {
      final setup = _Setup();
      await setup.pump(tester, brightness: brightness);
      await _type(tester, '看看 @');
      await pumpFrames(tester, 4);
      await expectLater(
        find.byType(ChatScreen),
        matchesGoldenFile('goldens/composer_mention_picker_${brightness.name}.png'),
      );
    });

    testWidgets('golden: chips in the draft (${brightness.name})', (tester) async {
      final setup = _Setup();
      await setup.pump(tester, brightness: brightness);
      await _type(tester, '对比 @');
      await tester.tap(find.text('修复登录重复提交'));
      await _settle(tester);
      final draft = _draft(tester);
      draft.value = TextEditingValue(
        text: '${draft.text}和 @',
        selection: TextSelection.collapsed(offset: draft.text.length + 3),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.tap(find.text('README.md'));
      await _settle(tester);
      draft.value = TextEditingValue(
        text: '${draft.text}有什么不同',
        selection: TextSelection.collapsed(offset: draft.text.length + 5),
      );
      await pumpFrames(tester, 4);
      await expectLater(
        find.byType(Composer),
        matchesGoldenFile('goldens/composer_mention_chips_${brightness.name}.png'),
      );
    });
  }
}
