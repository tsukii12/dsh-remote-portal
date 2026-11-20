import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/secret_mask.dart';
import 'package:dsh_app/ui/chat/widgets/background_task_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/pending_notice_harness.dart';

PendingPrompt notice(String text, {String id = 'job', String? form = 'notice'}) => PendingPrompt(
  requestId: id,
  text: text,
  time: DateTime(2026),
  inboxId: 'item-$id',
  sourceKind: 'tool-jobs',
  sourceForm: form,
);

Widget noticeApp(
  PendingPrompt prompt, {
  Locale locale = AppLocale.zhCN,
  Brightness brightness = Brightness.light,
  double scale = 1,
  GlobalKey? capture,
}) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocale.supported,
  localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
  theme: testTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: RepaintBoundary(
    key: capture,
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: BackgroundTaskNotice(prompt: prompt),
      ),
    ),
  ),
);

Future<void> preview(WidgetTester tester, GlobalKey key, String name) async {
  final path = Platform.environment['DSH_G56_PREVIEW_DIR'];
  if (path == null) return;
  await tester.runAsync(() async {
    final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory(path)..createSync(recursive: true);
      File('${directory.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void narrowView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.reset);
}

void main() {
  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('320dp notice layout and semantics: $locale $brightness $scale', (tester) async {
          narrowView(tester);
          final semantics = tester.ensureSemantics();
          try {
            final capture = GlobalKey();
            final body =
                '$backgroundNoticeBody\n\n'
                '命令、日志和任务标识仅作为文字显示。\n'
                'job-${'0123456789abcdef' * 8}\n'
                '[View output](https://example.test/output)\n'
                '{"source":{"kind":"user"}}';
            final title = locale == AppLocale.en ? 'Background task notice' : '后台任务通知';
            final name = '${locale.languageCode}-${brightness.name}-$scale';
            final captureCase =
                (locale == AppLocale.zhCN && brightness == Brightness.light && scale == 1) ||
                (locale == AppLocale.en && brightness == Brightness.dark && scale == 2);
            await tester.pumpWidget(
              noticeApp(notice(body), locale: locale, brightness: brightness, scale: scale, capture: capture),
            );
            await tester.pumpAndSettle();
            final header = tester.getRect(find.byType(TextButton));
            final collapsedHeight = tester.getSize(find.byType(BackgroundTaskNotice)).height;
            expect(header.height, greaterThanOrEqualTo(48));
            expect(header.left, closeTo(320 - header.right, 0.01));
            expect(header.left, greaterThanOrEqualTo(0));
            expect(collapsedHeight, lessThanOrEqualTo(120));
            if (scale == 1) expect(collapsedHeight, 48);
            expect(find.byType(SelectableText), findsNothing);
            final closed = tester.getSemantics(find.bySemanticsLabel(title)).getSemanticsData();
            expect(closed.label, title);
            expect(closed.flagsCollection.isButton, isTrue);
            expect(closed.flagsCollection.isExpanded, ui.Tristate.isFalse);
            expect(closed.hasAction(ui.SemanticsAction.tap), isTrue);
            expect(find.bySemanticsLabel(RegExp(r'^我(?:\n|$)')), findsNothing);
            if (captureCase) await preview(tester, capture, '$name-collapsed');

            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final detail = tester.widget<SelectableText>(find.byType(SelectableText));
            expect(detail.data, body);
            final detailBox = tester.getRect(find.byType(SelectableText));
            expect(detailBox.left, greaterThanOrEqualTo(0));
            expect(detailBox.right, lessThanOrEqualTo(320));
            final open = tester.getSemantics(find.bySemanticsLabel(title)).getSemanticsData();
            expect(open.label, title);
            expect(open.flagsCollection.isExpanded, ui.Tristate.isTrue);
            expect(find.byType(TextButton), findsOneWidget, reason: 'Body markup cannot create actions.');
            debugPrint(
              jsonEncode({
                'kind': 'G56_GEOMETRY',
                'case': name,
                'header': [header.left, header.top, header.width, header.height],
                'collapsedHeight': collapsedHeight,
                'expandedHeight': tester.getSize(find.byType(BackgroundTaskNotice)).height,
                'detail': [detailBox.left, detailBox.top, detailBox.width, detailBox.height],
              }),
              wrapWidth: 4096,
            );
            if (captureCase) await preview(tester, capture, '$name-expanded');
            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            expect(find.byType(SelectableText), findsNothing);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  testWidgets('the header is keyboard focusable and toggles with Enter', (tester) async {
    narrowView(tester);
    await tester.pumpWidget(noticeApp(notice(backgroundNoticeBody)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('expanded display and selection keep the existing secret mask', (tester) async {
    narrowView(tester);
    const body =
        'background job: https://demo:password@example.test/path\n'
        'sk-0123456789abcdef0123456789abcdef';
    final prompt = notice(body);
    await tester.pumpWidget(noticeApp(prompt));
    await tester.tap(find.text('后台任务通知'));
    await tester.pumpAndSettle();
    final displayed = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(displayed, maskSecrets(body, mark: '•'));
    expect(displayed, isNot(contains('password')));
    expect(displayed, isNot(contains('sk-0123456789abcdef0123456789abcdef')));
    expect(prompt.text, body, reason: 'Only display changes, not the inbox payload.');
  });

  testWidgets('an empty message has a stable non-actionable title', (tester) async {
    narrowView(tester);
    await tester.pumpWidget(noticeApp(notice('', form: null)));
    expect(find.text('后台任务消息'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.getSize(find.byType(TextButton)).height, greaterThanOrEqualTo(48));
  });

  testWidgets('ChatList session identity does not carry an expanded notice to another session', (tester) async {
    narrowView(tester);
    final prompt = notice(backgroundNoticeBody);
    final h = ChatHarness(
      states: {
        'a': ChatState(loading: false, pending: [prompt]),
        'b': ChatState(loading: false, pending: [prompt]),
      },
    );
    Widget screen(String sessionId) => testApp(
      Scaffold(body: ChatList(sessionId: sessionId, topInset: 0, bottomInset: 0)),
      overrides: h.overrides,
    );
    await tester.pumpWidget(screen('a'));
    await pumpFrames(tester);
    await tester.tap(find.text('后台任务通知'));
    await pumpFrames(tester);
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.pumpWidget(screen('b'));
    await tester.pump();
    expect(find.text('后台任务通知'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });
}
