// 「翻译」 in the expanded thinking view: offered only with the translation
// bundle on and reasoning outside Chinese; the translation replaces the text
// in place with a toggle back; failures keep the original with a retry.
// Goldens: `flutter test --update-goldens test/agents/thinking_translate_test.dart`.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/cot_translation_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

const _english =
    'The user wants double taps on the login button to send one request.\n\n'
    'I should disable the button while the request is in flight, then '
    're-enable it when the response arrives.';

const _limits = CotTranslationLimits(
  maxTextChars: 4000,
  provider: 'bing',
  targetLanguage: 'auto',
  availableProviders: ['bing', 'google'],
);

const _translations = {
  'The user wants double taps on the login button to send one request.': '用户希望连点登录按钮时只发出一次请求。',
  'I should disable the button while the request is in flight, then '
          're-enable it when the response arrives.':
      '我应该在请求进行中禁用按钮，收到响应后再恢复。',
};

class _Translator {
  final asked = <(String, String?, String)>[];
  bool fail = false;

  Future<String> call(String text, {required CotTranslationLimits limits, String? sessionId}) async {
    asked.add((text, sessionId, limits.targetFor(reasoningUiLanguage)));
    if (fail) throw StateError('offline');
    return _translations[text] ?? text;
  }
}

Widget _app(
  String reasoning, {
  CotTranslationLimits? limits = _limits,
  _Translator? translator,
  Brightness brightness = Brightness.light,
}) => testApp(
  Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.topLeft,
          child: ThinkingPill(reasoning: reasoning),
        ),
      ),
    ),
  ),
  brightness: brightness,
  overrides: [
    currentSessionProvider.overrideWith(() => FixedSession('s1')),
    cotTranslationProvider.overrideWith((ref) async => limits),
    reasoningTranslatorProvider.overrideWithValue((translator ?? _Translator()).call),
  ],
);

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('思考'));
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('translate, show the original, back to the translation', (tester) async {
    final translator = _Translator();
    await tester.pumpWidget(_app(_english, translator: translator));
    await pumpFrames(tester, 2);
    expect(find.text('翻译'), findsNothing);
    await _expand(tester);
    expect(find.text('翻译'), findsOneWidget);
    await tester.tap(find.text('翻译'));
    await pumpFrames(tester, 4);
    expect(translator.asked.map((a) => a.$2), ['s1', 's1']);
    expect(translator.asked.map((a) => a.$3).toSet(), {'zh'});
    expect(find.textContaining('只发出一次请求'), findsOneWidget);
    expect(find.text('查看原文'), findsOneWidget);
    await tester.tap(find.text('查看原文'));
    await pumpFrames(tester, 2);
    expect(find.textContaining('double taps'), findsOneWidget);
    expect(find.text('查看译文'), findsOneWidget);
    await tester.tap(find.text('查看译文'));
    await pumpFrames(tester, 2);
    expect(find.textContaining('只发出一次请求'), findsOneWidget);

    // Collapse and reopen: the translation is still there, nothing re-sent.
    await tester.tap(find.text('思考'));
    await pumpFrames(tester, 6);
    await _expand(tester);
    expect(find.textContaining('只发出一次请求'), findsOneWidget);
    expect(translator.asked, hasLength(2));
  });

  testWidgets('not offered without the bundle or for Chinese reasoning', (tester) async {
    await tester.pumpWidget(_app(_english, limits: null));
    await pumpFrames(tester, 2);
    await _expand(tester);
    expect(find.textContaining('double taps'), findsOneWidget);
    expect(find.text('翻译'), findsNothing);

    await tester.pumpWidget(_app('先确认按钮在请求期间是否禁用。\n\n再补一个连点测试。'));
    await pumpFrames(tester, 2);
    await _expand(tester);
    expect(find.text('翻译'), findsNothing);
  });

  testWidgets('in the English interface, auto translates Chinese reasoning into English', (tester) async {
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final translator = _Translator();
    await tester.pumpWidget(_app('先确认按钮在请求期间是否禁用。', translator: translator));
    await pumpFrames(tester, 2);
    await tester.tap(find.text('Thinking'));
    await pumpFrames(tester, 6);
    await tester.tap(find.text('Translate'));
    await pumpFrames(tester, 4);
    expect(translator.asked.map((a) => a.$3), ['en']);
  });

  testWidgets('switching the interface language drops the translation until asked again', (tester) async {
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final translator = _Translator();
    await tester.pumpWidget(_app(_english, translator: translator));
    await pumpFrames(tester, 2);
    await _expand(tester);
    await tester.tap(find.text('翻译'));
    await pumpFrames(tester, 4);
    expect(find.textContaining('只发出一次请求'), findsOneWidget);
    expect(translator.asked, hasLength(2));

    AppLocale.use(AppLocale.en);
    await tester.pumpWidget(_app(_english, translator: translator));
    await pumpFrames(tester, 2);
    expect(find.textContaining('只发出一次请求'), findsNothing);
    expect(find.textContaining('double taps'), findsOneWidget);
    // English reasoning in the English interface: nothing to translate.
    expect(find.text('Translate'), findsNothing);
    expect(translator.asked, hasLength(2));

    AppLocale.use(AppLocale.zhCN);
    await tester.pumpWidget(_app(_english, translator: translator));
    await pumpFrames(tester, 2);
    expect(find.textContaining('只发出一次请求'), findsNothing);
    await tester.tap(find.text('翻译'));
    await pumpFrames(tester, 4);
    expect(find.textContaining('只发出一次请求'), findsOneWidget);
    expect(translator.asked, hasLength(4));
  });

  testWidgets('a failure keeps the original and offers a retry', (tester) async {
    final translator = _Translator()..fail = true;
    await tester.pumpWidget(_app(_english, translator: translator));
    await pumpFrames(tester, 2);
    await _expand(tester);
    await tester.tap(find.text('翻译'));
    await pumpFrames(tester, 4);
    expect(find.text('翻译暂不可用'), findsOneWidget);
    expect(find.textContaining('double taps'), findsOneWidget);
    translator.fail = false;
    await tester.tap(find.text('重试'));
    await pumpFrames(tester, 4);
    expect(find.text('翻译暂不可用'), findsNothing);
    expect(find.textContaining('只发出一次请求'), findsOneWidget);
  });

  testWidgets('the chip: equal insets, icon and label centred', (tester) async {
    await tester.pumpWidget(_app(_english));
    await pumpFrames(tester, 2);
    await _expand(tester);
    final chip = tester.getRect(find.ancestor(of: find.text('翻译'), matching: find.byType(Container)).first);
    final icon = tester.getRect(find.byIcon(AppIcons.translate));
    final label = tester.getRect(find.text('翻译'));
    expect(icon.left - chip.left, closeTo(10, 0.01));
    expect(chip.right - label.right, closeTo(10, 0.01));
    expect(icon.center.dy, closeTo(chip.center.dy, 0.5));
    expect(label.center.dy, closeTo(chip.center.dy, 0.5));
    expect(chip.height, greaterThanOrEqualTo(26));
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: translated reasoning ($mode)', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 560);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_english, brightness: brightness));
      await pumpFrames(tester, 2);
      await _expand(tester);
      await tester.tap(find.text('翻译'));
      await pumpFrames(tester, 4);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/thinking_translated_$mode.png'));
    });

    testWidgets('golden: offer ($mode)', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 560);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_english, brightness: brightness));
      await pumpFrames(tester, 2);
      await _expand(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/thinking_offer_$mode.png'));
    });
  }
}
