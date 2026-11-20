// The risk notice (ui/common/risk_notice.dart): when each tier shows, what
// 「不再提示」 stores, where 「问 AI」 goes, and the sheet's geometry — the main
// key on both 20 gutters, the checkbox's square on the same edge, the 问 AI
// key centred with even room inside, the × level with the title's first line —
// at 320 and 390 wide and 1, 1.3 and 2× text, in light and dark.
//
//   flutter test --update-goldens test/common/risk_notice_test.dart

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/risk_notice_store.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/ask_ai.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

class MemoryRiskStore implements RiskNoticeStore {
  final ids = <String>{};

  @override
  Future<bool> silenced(String id) async => ids.contains(id);

  @override
  Future<void> silence(String id) async => ids.add(id);
}

class FixedHost extends ActiveHostController {
  FixedHost(this.host);

  final HostRef host;

  @override
  HostRef build() => host;
}

/// Opens the notice from a key; [results] collects what [confirmRisk] said.
class _Bench {
  _Bench(this.tester, this.results);

  final WidgetTester tester;
  final List<bool> results;

  Future<void> open() async {
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  ProviderContainer get container => ProviderScope.containerOf(tester.element(find.text('打开')));
}

Future<_Bench> _pump(
  WidgetTester tester,
  RiskNotice Function() notice, {
  Brightness brightness = Brightness.light,
  double width = 390,
  double scale = 1,
  RiskNoticeStore? store,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
  final results = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        riskNoticeStoreProvider.overrideWithValue(store ?? MemoryRiskStore()),
        activeHostProvider.overrideWith(() => FixedHost(HostRef.none)),
        activeConnectionProvider.overrideWithValue(const AsyncValue.data(null)),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withTestFonts(buildLightTheme()),
        darkTheme: withTestFonts(buildDarkTheme()),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
          child: MirroredSideInsets(child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(await confirmRisk(context, notice())),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Bench(tester, results);
}

Finder get _sheet => find.byType(RiskNoticeSheet);
Finder get _confirm => find.byKey(const ValueKey('risk-confirm'));
Finder get _close => find.descendant(of: find.byType(SheetHeader), matching: find.byType(SheetIconButton));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('high: every time', () {
    testWidgets('no 不再提示; × and back say no, the main key yes, and it asks again', (tester) async {
      final store = MemoryRiskStore();
      final bench = await _pump(tester, () => RiskNotices.phoneConfirmAlways, store: store);

      await bench.open();
      expect(find.text('始终免确认？'), findsOneWidget);
      expect(find.text('打开 App、点按、发送、删除都直接做，不再问你。'), findsOneWidget);
      expect(find.descendant(of: _confirm, matching: find.text('始终免确认')), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      // The danger colour, with its own text colour.
      final style = tester.widget<FilledButton>(_confirm).style!;
      final colors = DshColors.of(tester.element(_sheet));
      expect(style.backgroundColor!.resolve({}), colors.danger);
      expect(style.foregroundColor!.resolve({}), colors.onDanger);
      // Locked: no handle, the × closes.
      expect(find.byType(SheetDragHandle), findsNothing);
      await tester.tap(_close);
      await tester.pumpAndSettle();
      expect(bench.results, [false]);

      await bench.open();
      // System back.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(bench.results, [false, false]);

      await bench.open();
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(bench.results, [false, false, true]);

      await bench.open();
      expect(_sheet, findsOneWidget, reason: 'a high notice never goes quiet');
      expect(store.ids, isEmpty);
    });

    testWidgets('the scrim does not close it', (tester) async {
      final bench = await _pump(tester, () => RiskNotices.fullAccess);
      await bench.open();
      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();
      expect(_sheet, findsOneWidget);
    });
  });

  group('medium: first time', () {
    testWidgets('不再提示 is ticked; confirming silences it for good', (tester) async {
      final store = MemoryRiskStore();
      final bench = await _pump(tester, () => RiskNotices.allowForChat, store: store);

      await bench.open();
      expect(find.text('本对话都允许？'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(find.text('不再提示'), findsOneWidget);
      // The primary colour: a bounded risk.
      expect(tester.widget<FilledButton>(_confirm).style!.backgroundColor, isNull);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(bench.results, [true]);
      expect(store.ids, {'chat.allow-for-chat'});

      await bench.open();
      expect(_sheet, findsNothing);
      expect(bench.results, [true, true]);
    });

    testWidgets('unticked it asks again; × stores nothing', (tester) async {
      final store = MemoryRiskStore();
      final bench = await _pump(tester, () => RiskNotices.autoReview, store: store);

      await bench.open();
      await tester.tap(_close);
      await tester.pumpAndSettle();
      expect(bench.results, [false]);
      expect(store.ids, isEmpty);

      await bench.open();
      // The whole line toggles, not just the box.
      await tester.tap(find.text('不再提示'));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(bench.results, [false, true]);
      expect(store.ids, isEmpty);

      await bench.open();
      expect(_sheet, findsOneWidget);
    });

    test('不再提示 is kept in preferences across launches', () async {
      SharedPreferences.setMockInitialValues({});
      const store = PrefsRiskNoticeStore();
      expect(await store.silenced('chat.allow-for-chat'), isFalse);
      await store.silence('chat.allow-for-chat');
      await store.silence('pets.overlay-permission');
      await store.silence('chat.allow-for-chat');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(PrefsRiskNoticeStore.key), ['chat.allow-for-chat', 'pets.overlay-permission']);
      expect(await const PrefsRiskNoticeStore().silenced('chat.allow-for-chat'), isTrue);
      expect(await const PrefsRiskNoticeStore().silenced('permission.auto-review'), isFalse);
    });
  });

  group('问 AI', () {
    testWidgets('closes the notice, does not go ahead, and opens the question', (tester) async {
      final store = MemoryRiskStore();
      final bench = await _pump(tester, () => RiskNotices.allowForChat, store: store);
      await bench.open();
      await tester.tap(find.text('不确定？问 AI'));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      expect(bench.results, [false]);
      expect(store.ids, isEmpty, reason: 'asking is not confirming');
      final queued = bench.container.read(composeInboxProvider).single;
      expect(queued.text, '/dsh-go-guide 「本对话都允许」会放行哪些操作？怎么关掉？');
    });

    testWidgets('only where the guide covers the topic', (tester) async {
      final bench = await _pump(tester, () => RiskNotices.autoReview);
      await bench.open();
      expect(find.byType(AskAiLink), findsNothing);
    });

    testWidgets('never in 网页模式', (tester) async {
      final bench = await _pump(
        tester,
        () => RiskNotices.fullAccess,
        overrides: [askAiAvailableProvider.overrideWithValue(false)],
      );
      await bench.open();
      expect(find.byType(AskAiLink), findsNothing);
      // The notice itself still guards the switch.
      expect(_confirm, findsOneWidget);
    });

    testWidgets('every notice with a question has one', (tester) async {
      final notices = [
        RiskNotices.phoneConfirmAlways,
        RiskNotices.appRule('支付宝', fromDeny: true),
        RiskNotices.appRule('微信', fromDeny: false),
        RiskNotices.fullAccess,
        RiskNotices.phoneFiles,
        RiskNotices.allowForChat,
      ];
      for (final n in notices) {
        expect(n.ask, isNotNull, reason: n.id);
        expect(n.ask!.question, isNotEmpty);
      }
      expect(RiskNotices.autoReview.ask, isNull);
      expect(RiskNotices.petOverlay.ask, isNull);
      expect(RiskNotices.rootChannel.ask, isNull);
      // High where a whole class of checks goes; medium where it is bounded.
      expect(
        {
          for (final n in [...notices, RiskNotices.autoReview, RiskNotices.petOverlay, RiskNotices.rootChannel])
            n.id: n.level,
        },
        {
          'phone.confirm-always': RiskLevel.high,
          'phone.app-rule.allow': RiskLevel.high,
          'phone.app-rule.skip-steps': RiskLevel.high,
          'permission.full-access': RiskLevel.high,
          'settings.phone-files': RiskLevel.high,
          'chat.allow-for-chat': RiskLevel.medium,
          'permission.auto-review': RiskLevel.medium,
          'pets.overlay-permission': RiskLevel.medium,
          // Only the root manager's own prompt comes next: said once.
          'phone.root': RiskLevel.medium,
        },
      );
    });
  });

  group('geometry', () {
    for (final width in [320.0, 390.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final medium in [false, true]) {
          final tier = medium ? 'medium' : 'high';
          testWidgets('$tier at $width wide, ${scale}x text: symmetric, nothing cut', (tester) async {
            final bench = await _pump(
              tester,
              () => medium ? RiskNotices.allowForChat : RiskNotices.appRule('支付宝', fromDeny: true),
              width: width,
              scale: scale,
            );
            await bench.open();
            expect(tester.takeException(), isNull);

            final sheet = tester.getRect(_sheet);
            final key = tester.getRect(_confirm);
            // The main key: 20 from both sides, at least 48 tall.
            expect(key.left - sheet.left, moreOrLessEquals(kSheetGutter, epsilon: .01));
            expect(sheet.right - key.right, moreOrLessEquals(kSheetGutter, epsilon: .01));
            expect(key.height, greaterThanOrEqualTo(RiskNoticeSheet.buttonHeight));

            // Nothing in the sheet is cut short or spills.
            for (final paragraph in tester.renderObjectList<RenderParagraph>(
              find.descendant(of: _sheet, matching: find.byType(RichText)),
            )) {
              expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
              final box = paragraph.localToGlobal(Offset.zero) & paragraph.size;
              expect(box.left, greaterThanOrEqualTo(sheet.left));
              expect(box.right, lessThanOrEqualTo(sheet.right + .01), reason: paragraph.text.toPlainText());
            }

            // The title's first line and the × share a centre line.
            final title = tester.renderObject<RenderParagraph>(
              find.descendant(of: find.byType(SheetHeader), matching: find.byType(RichText)).first,
            );
            final titleTop = title.localToGlobal(Offset.zero).dy;
            final firstLine = title.getFullHeightForCaret(const TextPosition(offset: 0));
            final closeCircle = tester.getRect(find.descendant(of: _close, matching: find.byType(DecoratedBox)).first);
            expect(titleTop + firstLine / 2, moreOrLessEquals(closeCircle.center.dy, epsilon: 1));
            expect(sheet.right - closeCircle.right, moreOrLessEquals(kSheetGutter, epsilon: .01));

            // 问 AI: centred, the same room before the sparkle as after the words.
            final link = tester.getRect(find.byType(AskAiLink));
            expect(link.center.dx, moreOrLessEquals(sheet.center.dx, epsilon: .5));
            final sparkle = tester.getRect(
              find.descendant(of: find.byType(AskAiLink), matching: find.byIcon(AppIcons.askAi)),
            );
            final words = tester.getRect(
              find.descendant(of: find.byType(AskAiLink), matching: find.byType(RichText)).last,
            );
            expect(sparkle.center.dy, moreOrLessEquals(words.center.dy, epsilon: 1));
            // The sparkle grows with the words, and its own air with it.
            expect(sparkle.height, moreOrLessEquals(AskAiLink.iconSize * scale, epsilon: .01));
            final before = sparkle.left + AskAiLink.leadingAir * scale - link.left;
            final after = link.right - words.right;
            expect(before, moreOrLessEquals(after, epsilon: .5));
            expect(link.top - key.bottom, greaterThanOrEqualTo(4));

            if (medium) {
              // The checkbox's square sits on the main key's left edge.
              final box = tester.getRect(find.byType(Checkbox));
              expect(box.center.dx - 9, moreOrLessEquals(key.left, epsilon: .5));
              final label = tester.getRect(find.text('不再提示'));
              expect(label.center.dy, moreOrLessEquals(box.center.dy, epsilon: 1));
            } else {
              expect(find.byType(Checkbox), findsNothing);
            }
          });
        }
      }
    }
  });

  group('goldens', () {
    for (final brightness in Brightness.values) {
      for (final medium in [false, true]) {
        final mode = brightness.name;
        final tier = medium ? 'medium' : 'high';
        testWidgets('$tier ($mode)', (tester) async {
          await tester.runAsync(loadTestFonts);
          final bench = await _pump(
            tester,
            () => medium ? RiskNotices.allowForChat : RiskNotices.phoneConfirmAlways,
            brightness: brightness,
          );
          await bench.open();
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/risk_notice_${tier}_$mode.png'));
        });
      }
    }

    testWidgets('320 wide, 2x text (light)', (tester) async {
      await tester.runAsync(loadTestFonts);
      final bench = await _pump(tester, () => RiskNotices.appRule('支付宝', fromDeny: true), width: 320, scale: 2);
      await bench.open();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/risk_notice_large_text_light.png'));
    });
  });

  testWidgets('English copy fits at 320 wide, 2x text', (tester) async {
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    for (final notice in [
      RiskNotices.phoneConfirmAlways,
      RiskNotices.appRule('Alipay', fromDeny: false),
      RiskNotices.phoneFiles,
      RiskNotices.allowForChat,
      RiskNotices.petOverlay,
    ]) {
      final bench = await _pump(tester, () => notice, width: 320, scale: 2);
      await bench.open();
      expect(tester.takeException(), isNull, reason: notice.id);
      expect(find.text(notice.title), findsOneWidget);
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: _sheet, matching: find.byType(RichText)),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
      }
      await tester.tap(_close);
      await tester.pumpAndSettle();
    }
  });
}
