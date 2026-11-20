// One menu for every message: a preview, then what you do with this message,
// then — in its own card — what opens a new conversation. The order is the
// menu's, not the caller's. Pictures get the same sheet with the picture as
// the preview. 「选择文字」 offers 「引用」 for the selected passage.

import 'dart:convert';

import 'package:dsh_app/ui/chat/widgets/message_menu.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _reply =
    '是**超时重试**多发了一次请求：第一次在 30 秒时超时，客户端重试，'
    '而服务端其实已经处理完了第一次。';

/// An 8×8 blue gradient PNG, drawn as a swatch in the preview.
final _pixel = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAIElEQVQI12P0zf7HgA2w8HAxYJfg5mYgUQcPNyOt7QAAmqsCcBesOqQAAAAASUVORK5CYII=',
  ),
);

/// A page with one button that runs [open]; what it resolves to lands in
/// [result].
Future<void> _host(
  WidgetTester tester,
  Future<Object?> Function(BuildContext context) open, {
  Brightness brightness = Brightness.light,
  List<Object?>? result,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      brightness: brightness,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final value = await open(context);
                result?.add(value);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// Decodes the pictures on screen (decoding is real I/O in tests).
Future<void> _decodeImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pumpAndSettle();
}

List<String> _labels(WidgetTester tester, Finder group) => [
  for (final tile in tester.widgetList<SettingsTile>(find.descendant(of: group, matching: find.byType(SettingsTile))))
    tile.title!,
];

void main() {
  setUpAll(loadTestFonts);

  testWidgets('message actions first, then the ones that fork, in menu order', (tester) async {
    final result = <Object?>[];
    await _host(
      tester,
      (context) => showMessageMenu(
        context,
        text: _reply,
        // Deliberately shuffled: the menu keeps its own order.
        actions: const [
          MessageAction.branch,
          MessageAction.share,
          MessageAction.copy,
          MessageAction.regenerate,
          MessageAction.quote,
          MessageAction.selectText,
        ],
      ),
      result: result,
    );
    final groups = find.byType(SheetGroup);
    expect(groups, findsNWidgets(2));
    expect(_labels(tester, groups.at(0)), ['复制', '选择文字', '引用', '分享']);
    expect(_labels(tester, groups.at(1)), ['重新回答', '从这里分叉']);
    // The preview drops Markdown marks.
    expect(find.textContaining('是超时重试多发了一次请求'), findsOneWidget);
    expect(find.text('在新对话中重新生成，原对话不变'), findsOneWidget);

    await tester.tap(find.widgetWithText(SettingsTile, '重新回答'));
    await tester.pumpAndSettle();
    expect(result, [MessageAction.regenerate]);
  });

  testWidgets('a prompt\'s menu has the same two cards', (tester) async {
    await _host(
      tester,
      (context) => showMessageMenu(
        context,
        text: '帮我看看测试为什么失败',
        actions: const [MessageAction.copy, MessageAction.selectText, MessageAction.edit],
      ),
    );
    final groups = find.byType(SheetGroup);
    expect(groups, findsNWidgets(2));
    expect(_labels(tester, groups.at(0)), ['复制', '选择文字']);
    expect(_labels(tester, groups.at(1)), ['编辑后重发']);
  });

  testWidgets('without fork actions there is one card', (tester) async {
    await _host(
      tester,
      (context) =>
          showMessageMenu(context, text: '再看看依赖', actions: const [MessageAction.copy, MessageAction.selectText]),
    );
    expect(find.byType(SheetGroup), findsOneWidget);
  });

  testWidgets('a picture\'s menu: its thumbnail and name, save and share', (tester) async {
    final result = <Object?>[];
    await _host(
      tester,
      (context) => showImageMenu(context, image: _pixel, name: 'chart.png'),
      result: result,
    );
    await _decodeImages(tester);
    expect(find.text('chart.png'), findsOneWidget);
    expect(_labels(tester, find.byType(SheetGroup)), ['保存到相册', '分享']);
    await tester.tap(find.widgetWithText(SettingsTile, '保存到相册'));
    await tester.pumpAndSettle();
    expect(result, [ImageAction.save]);
  });

  testWidgets('选择文字: the toolbar quotes the selection', (tester) async {
    final quoted = <String>[];
    await _host(tester, (context) => showSelectTextSheet(context, _reply, markdown: true, onQuote: quoted.add));
    expect(find.byType(SelectionArea), findsOneWidget);
    await tester.longPress(find.textContaining('服务端', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsOneWidget);
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(quoted, hasLength(1));
    expect(quoted.single.trim(), isNotEmpty);
    expect(_reply.replaceAll('**', ''), contains(quoted.single.trim()));
    // The sheet closed with it.
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('选择文字 of a prompt has no 引用', (tester) async {
    await _host(tester, (context) => showSelectTextSheet(context, '帮我看看测试为什么失败'));
    await tester.longPress(find.text('帮我看看测试为什么失败'));
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: a reply\'s menu (${brightness.name})', (tester) async {
      await _host(
        tester,
        brightness: brightness,
        (context) => showMessageMenu(
          context,
          text: _reply,
          actions: const [
            MessageAction.copy,
            MessageAction.selectText,
            MessageAction.quote,
            MessageAction.share,
            MessageAction.regenerate,
            MessageAction.branch,
          ],
        ),
      );
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/message_menu_${brightness.name}.png'));
    });

    testWidgets('golden: a picture\'s menu (${brightness.name})', (tester) async {
      await _host(
        tester,
        brightness: brightness,
        (context) => showImageMenu(context, image: _pixel, name: 'chart.png'),
      );
      await _decodeImages(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/image_menu_${brightness.name}.png'));
    });
  }
}
