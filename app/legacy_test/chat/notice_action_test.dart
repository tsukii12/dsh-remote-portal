import 'dart:async';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_app/update/version.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

NoticeChatItem notice({String kind = 'error', String code = 'TIMEOUT', String message = 'raw English error'}) =>
    NoticeChatItem(
      seq: 10,
      kind: kind,
      text: message,
      failure: LlmFailure(code: code, message: message),
    );

TurnTrace turn() =>
    TurnTrace(turn: 1, startSeq: 0, start: DateTime(2026), endSeq: 10, end: DateTime(2026), spans: const []);

Future<ChatHarness> mount(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 3);
  return harness;
}

void main() {
  setUpAll(loadTestFonts);
  testWidgets('a text-only failed turn retries the original prompt', (tester) async {
    final harness = await mount(tester, ChatState(loading: false, items: [user(1, '原文'), notice()], turns: [turn()]));
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('raw English'), findsNothing);
    final button = find.widgetWithText(TextButton, '重试');
    final lead = find.descendant(
      of: find.byType(NoticeRow),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == StreamRow.lead && w.height == StreamRow.lead),
    );
    expect(tester.getSize(button).height, StreamRow.lead);
    expect(tester.getCenter(button).dy, closeTo(tester.getCenter(lead).dy, 0.5));
    await tester.tap(button);
    await tester.pump();
    expect(harness.controllers['s1']!.sent, ['原文']);
  });
  testWidgets('missing turn history never infers retry from an arbitrary earlier user', (tester) async {
    final harness = await mount(tester, ChatState(loading: false, items: [user(1, 'old input'), notice()]));
    expect(find.widgetWithText(TextButton, '重试'), findsNothing);
    expect(find.widgetWithText(TextButton, '继续'), findsNothing);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });
  for (final olderPrompt in [false, true]) {
    testWidgets('an unechoed failed turn never retries an older prompt: $olderPrompt', (tester) async {
      final harness = await mount(
        tester,
        ChatState(
          loading: false,
          items: [if (olderPrompt) user(1, 'previous turn'), notice()],
          turns: [
            TurnTrace(turn: 2, startSeq: 8, start: DateTime(2026), endSeq: 10, end: DateTime(2026), spans: const []),
          ],
        ),
      );
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
      expect(find.widgetWithText(TextButton, '继续'), findsNothing);
      expect(harness.controllers['s1']!.sent, isEmpty);
    });
  }
  testWidgets('a failed submission stays editable with attachments without overwriting a newer draft', (tester) async {
    final image = DraftAttachment.sniff('saved.png', tinyPng);
    final failed = PendingPrompt(
      requestId: 'failed-request',
      text: 'retained original',
      time: DateTime(2026),
      attachments: [image],
      failureSeq: 10,
    );
    final harness = await mount(tester, ChatState(loading: false, items: [notice()], pending: [failed]));
    await tester.enterText(find.byType(TextField), 'newer draft');
    await tester.pump();
    expect(find.text('未送达 · 已保留'), findsOneWidget);
    expect(find.text('发送中'), findsNothing);
    await tester.tap(find.text('编辑后重发'));
    await pumpFrames(tester, 4);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'edited original');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await pumpFrames(tester, 4);
    expect(find.text('retained original'), findsOneWidget);
    expect(harness.controllers['s1']!.sent, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'newer draft');
    await tester.tap(find.text('编辑后重发'));
    await pumpFrames(tester, 4);
    await tester.enterText(find.byType(TextFormField), 'edited original');
    await tester.tap(find.widgetWithText(TextButton, '发送'));
    await pumpFrames(tester, 4);
    expect(harness.controllers['s1']!.sent, ['edited original']);
    expect(harness.controllers['s1']!.sentAttachments.single, [image]);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'newer draft');
  });
  for (final pending in [false, true]) {
    testWidgets('context overflow opens the model picker without replaying input: pending=$pending', (tester) async {
      final harness = await mount(
        tester,
        ChatState(
          loading: false,
          items: [
            user(1, 'retained original'),
            notice(code: 'CONTEXT_WINDOW_EXCEEDED'),
          ],
          turns: [turn()],
          pending: pending
              ? [PendingPrompt(requestId: 'failed', text: 'retained', time: DateTime(2026), failureSeq: 10)]
              : const [],
        ),
      );
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
      expect(find.widgetWithText(TextButton, '继续'), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      await tester.tap(find.widgetWithText(TextButton, '换模型'));
      await pumpFrames(tester, 4);
      expect(find.text('选择模型'), findsOneWidget);
      expect(harness.controllers['s1']!.models, isEmpty, reason: 'Opening the picker does not choose a model.');
      expect(harness.controllers['s1']!.sent, isEmpty, reason: 'The oversized request must not be replayed.');
      expect(container.read(chatProvider('s1')).pending, hasLength(pending ? 1 : 0));
    });
  }
  testWidgets('unsupported effort offers a user-controlled model/effort picker even with failed input', (tester) async {
    final harness = await mount(
      tester,
      ChatState(
        loading: false,
        items: [notice(code: 'UNSUPPORTED_REASONING_EFFORT')],
        pending: [PendingPrompt(requestId: 'failed', text: 'retained', time: DateTime(2026), failureSeq: 10)],
      ),
    );
    expect(find.text('当前模型不支持此推理档位，请调整档位或换模型'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsNothing);
    expect(harness.controllers['s1']!.models, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '换模型'));
    await pumpFrames(tester, 4);
    expect(find.text('选择模型'), findsOneWidget);
    expect(harness.controllers['s1']!.models, isEmpty, reason: 'Opening the picker must not change the selection.');
    expect(harness.controllers['s1']!.sent, isEmpty);
  });
  for (final kind in ['interrupted', 'max-tokens']) {
    testWidgets('$kind can continue', (tester) async {
      final harness = await mount(
        tester,
        ChatState(
          loading: false,
          items: [
            user(1, '原文'),
            notice(kind: kind),
          ],
          turns: [turn()],
        ),
      );
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(harness.controllers['s1']!.sent, ['继续']);
    });
  }
  testWidgets('a turn with attachments continues without resending attachments', (tester) async {
    final prompt = UserChatItem(
      seq: 1,
      time: DateTime(2026),
      text: '看图',
      images: const [ImageAttachment(attachmentId: 'img', mediaType: 'image/png')],
      files: const [],
    );
    final harness = await mount(tester, ChatState(loading: false, items: [prompt, notice()], turns: [turn()]));
    await tester.tap(find.text('继续'));
    await tester.pump();
    expect(harness.controllers['s1']!.sent, ['继续']);
  });
  for (final variant in [
    'older',
    'running',
    'pending',
    'AUTH',
    'QUOTA',
    'ACCOUNT_QUOTA',
    'CLIENT_UPGRADE_REQUIRED',
    'MODEL_UNSUPPORTED',
  ]) {
    testWidgets('$variant has no repeat action', (tester) async {
      await mount(
        tester,
        ChatState(
          loading: false,
          running: variant == 'running',
          items: [
            user(1, '原文'),
            notice(code: variant),
            if (variant == 'older') user(20, '下一轮'),
          ],
          turns: [turn()],
          pending: variant != 'pending' ? const [] : [PendingPrompt(requestId: 'p', text: '等待', time: DateTime(2026))],
        ),
      );
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
      expect(find.widgetWithText(TextButton, '继续'), findsNothing);
    });
  }
  group('the engine refuses the model (DSH 0.2.1-rc.4 listed catalog)', () {
    const unsupported =
        'DeepSeek model "deepseek-x" is not supported by DeepSeek Harness; current version is 0.2.1-rc.4';
    const upgrade =
        'DeepSeek model "deepseek-v5" requires DeepSeek Harness 0.3.0 or later; current version is 0.2.1-rc.4';

    Future<ChatHarness> refused(
      WidgetTester tester,
      String code,
      String message, {
      List<Override> extra = const [],
    }) async {
      usePhoneView(tester);
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            loading: false,
            items: [
              user(1, '原文'),
              notice(code: code, message: message),
            ],
          ),
        },
        extra: extra,
      );
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await pumpFrames(tester, 3);
      return harness;
    }

    testWidgets('an unsupported model offers 换模型: a fresh catalog, then the sheet', (tester) async {
      final harness = await refused(tester, 'MODEL_UNSUPPORTED', unsupported);
      expect(find.text('当前模型不可用'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsNothing);
      final reads = harness.catalogReads;
      await tester.tap(find.widgetWithText(TextButton, '换模型'));
      await pumpFrames(tester, 4);
      expect(harness.catalogReads, reads + 1);
      expect(find.text('选择模型'), findsOneWidget);
      await tester.tap(find.text('V41 Flash'));
      await pumpFrames(tester, 2);
      expect(harness.controllers['s1']!.models.single.model, 'deepseek-flash');
    });

    // The sheet is for the conversation it was opened over. What is open can
    // change under it while the Host lists models again: the conversation
    // deleted on the host (currentSession goes to null, 新对话), another
    // conversation chosen. A model picked then goes to neither.
    for (final (name, next) in [('deleted on the host', null), ('switched to another', 's2')]) {
      testWidgets('换模型, the conversation $name while the catalog is read: the pick goes nowhere', (tester) async {
        final harness = await refused(tester, 'MODEL_UNSUPPORTED', unsupported);
        final c = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
        harness.catalogHold = Completer<void>();
        await tester.tap(find.widgetWithText(TextButton, '换模型'));
        await pumpFrames(tester, 4);
        // Still reading: the last catalog shows, read-only, its heading says so.
        expect(find.textContaining('选择模型 · '), findsOneWidget);

        c.read(currentSessionProvider.notifier).select(next);
        harness.catalogHold!.complete();
        await pumpFrames(tester, 4);
        await tester.tap(find.text('V41 Flash'));
        await pumpFrames(tester, 2);
        expect(c.read(pendingModelProvider), isNull);
        expect(harness.controllers['s1']!.models, isEmpty);
        expect(harness.controllers['s2']?.models ?? const [], isEmpty);
      });
    }

    testWidgets('the header\'s model sheet, the conversation switched under it: the pick goes nowhere', (tester) async {
      final harness = await refused(tester, 'MODEL_UNSUPPORTED', unsupported);
      final c = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('composer-model')));
      await pumpFrames(tester, 4);
      expect(find.text('选择模型'), findsOneWidget);

      c.read(currentSessionProvider.notifier).select('s2');
      await pumpFrames(tester, 2);
      await tester.tap(find.text('V41 Flash'));
      await pumpFrames(tester, 2);
      expect(harness.controllers['s1']!.models, isEmpty);
      expect(harness.controllers['s2']?.models ?? const [], isEmpty);
    });

    testWidgets('a model that needs a newer engine on this phone offers 检查更新', (tester) async {
      final update = _UpToDate();
      await refused(tester, 'CLIENT_UPGRADE_REQUIRED', upgrade, extra: [appUpdateProvider.overrideWith(() => update)]);
      expect(find.text('这个模型需要新版引擎'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '换模型'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '检查更新'));
      await pumpFrames(tester, 3);
      expect(update.checks, 1);
      expect(find.text('已是最新版本'), findsOneWidget);
    });

    testWidgets('on a remote host the engine is not the app’s: 换模型', (tester) async {
      await refused(
        tester,
        'CLIENT_UPGRADE_REQUIRED',
        upgrade,
        extra: [activeHostProvider.overrideWith(_RelayHost.new)],
      );
      expect(find.text('这个模型需要新版引擎'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '检查更新'), findsNothing);
      expect(find.widgetWithText(TextButton, '换模型'), findsOneWidget);
    });

    testWidgets('the raw message keeps the required version', (tester) async {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: NoticeRow(
              item: notice(code: 'CLIENT_UPGRADE_REQUIRED', message: upgrade),
            ),
          ),
        ),
      );
      await tester.tap(find.text('这个模型需要新版引擎'));
      await pumpFrames(tester, 4);
      expect(find.text('CLIENT_UPGRADE_REQUIRED\n$upgrade'), findsOneWidget);
    });
  });
  testWidgets('a lapsed subscription only offers sign in again', (tester) async {
    await mount(
      tester,
      ChatState(
        loading: false,
        items: [
          user(1, 'q'),
          notice(message: 'OAuth refresh failed for openai-codex', code: 'AUTH'),
        ],
      ),
    );
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsNothing);
    expect(find.widgetWithText(TextButton, '继续'), findsNothing);
  });
  for (final pi in [false, true]) {
    testWidgets('missing credential opens ${pi ? 'providers' : 'API key'} settings', (tester) async {
      final harness = ChatHarness(session: 's1');
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: NoticeRow(
              item: notice(code: 'MISSING_CREDENTIAL', message: pi ? 'llm-pi-ai missing' : 'missing'),
            ),
          ),
          overrides: harness.overrides,
        ),
      );
      await tester.tap(find.text('去设置'));
      await pumpFrames(tester, 5);
      expect(find.byType(pi ? ProvidersPage : ApiKeyPage), findsOneWidget);
    });
  }
  testWidgets('raw failure details are disclosed only on request', (tester) async {
    await tester.pumpWidget(testApp(Scaffold(body: NoticeRow(item: notice()))));
    expect(find.textContaining('raw English error'), findsNothing);
    await tester.tap(find.text('模型响应超时'));
    await pumpFrames(tester, 4);
    expect(find.text('TIMEOUT\nraw English error'), findsOneWidget);
  });
}

/// No newer release: a check answers 已是最新 without the network.
class _UpToDate extends AppUpdateController {
  var checks = 0;

  @override
  AppUpdateState build() => const AppUpdateState(loaded: true, current: AppVersion(0, 9, 7));

  @override
  Future<void> get ready async {}

  @override
  Future<UpdateCheckPhase> check() async {
    checks++;
    return UpdateCheckPhase.upToDate;
  }
}

/// A DSH Remote host is the active one.
class _RelayHost extends ActiveHostController {
  @override
  HostRef build() => const HostRef.portal('r1', name: 'Mac');
}
