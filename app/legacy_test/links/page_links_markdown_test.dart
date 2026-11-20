// A reply's `dshgo://open/<page>` link opens that page through the router;
// an unknown page gets the one-line toast and nothing else.

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

void main() {
  late AppLinks links;
  late LinkRouter router;
  late List<String> opened;

  setUp(() {
    links = AppLinks();
    router = LinkRouter(links.links, grace: Duration.zero);
    opened = [];
  });
  tearDown(() {
    router.dispose();
    links.dispose();
  });

  Future<void> pumpReply(WidgetTester tester, String markdown) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          linkRouterProvider.overrideWithValue(router),
          pageLinkResolverProvider.overrideWithValue((id, _) {
            opened.add(id);
            return Scaffold(body: Text('page $id'));
          }),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                const LinkHost(),
                MarkdownBody(text: markdown, selectable: false),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // The reply's own link callback, as a tap on the link calls it.
  void tapLink(WidgetTester tester, String url) =>
      tester.widget<GptMarkdown>(find.byType(GptMarkdown)).onLinkTap!(url, '');

  testWidgets('tapping a page link in a reply opens the page', (tester) async {
    await pumpReply(tester, '在这里改：[打开手机操控](dshgo://open/phone)');
    tapLink(tester, 'dshgo://open/phone');
    await tester.pumpAndSettle();
    expect(opened, ['phone']);
    expect(find.text('page phone'), findsOneWidget);
  });

  testWidgets('an unknown page shows one line and opens nothing', (tester) async {
    await pumpReply(tester, '[打开](dshgo://open/nope)');
    tapLink(tester, 'dshgo://open/nope');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(opened, isEmpty);
    expect(find.text('无法打开这个链接'), findsOneWidget);
  });
}
