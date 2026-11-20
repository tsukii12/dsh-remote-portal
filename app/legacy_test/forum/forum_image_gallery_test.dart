import 'package:dsh_app/forum/render/cooked.dart';
import 'package:dsh_app/ui/forum/forum_post_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

CookedImage picture(String name, {bool original = true}) => CookedImage(
  src: Uri.parse('https://example.test/$name-thumb.png'),
  fullSrc: original ? Uri.parse('https://example.test/$name-full.png') : null,
  alt: name,
  width: 100,
  height: 60,
);

void main() {
  testWidgets('post pictures form one group, without quoted or collapsed detail pictures', (tester) async {
    usePhoneView(tester);
    final first = picture('first');
    final second = picture('second', original: false);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ForumBlocks(
            blocks: [
              first,
              CookedQuote(body: [picture('quoted')]),
              CookedDetails(summary: 'More', body: [picture('inside')]),
              second,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tiles = tester.widgetList<ForumPostImage>(find.byType(ForumPostImage)).toList();
    expect(tiles, hasLength(3));
    expect(tiles[0].gallery, [first, second]);
    expect(tiles[0].initial, 0);
    expect(tiles[1].gallery, hasLength(1));
    expect(tiles[2].gallery, [first, second]);
    expect(tiles[2].initial, 1);
    await tester.tap(find.descendant(of: find.byWidget(tiles[2]), matching: find.byType(Image)));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    var current = tester.widget<Image>(
      find.descendant(of: find.byType(ForumImageViewer), matching: find.byType(Image)).hitTestable(),
    );
    expect((current.image as NetworkImage).url, 'https://example.test/second-thumb.png');
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    current = tester.widget<Image>(
      find.descendant(of: find.byType(ForumImageViewer), matching: find.byType(Image)).hitTestable(),
    );
    expect((current.image as NetworkImage).url, 'https://example.test/first-full.png');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(ForumImageViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lone forum picture still has a close key and no page counter', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(ForumImageViewer(image: picture('single'))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.text('1 / 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
