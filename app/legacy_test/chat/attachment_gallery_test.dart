import 'dart:async';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/image_gallery.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

// Distinct original payloads; the PNG decoder ignores bytes after IEND.
Uint8List _png(int marker) => Uint8List.fromList([...tinyPng, marker]);

List<DraftAttachment> _drafts() => [
  DraftAttachment.sniff('first.png', _png(1)),
  DraftAttachment(name: 'notes.txt', bytes: Uint8List.fromList([65])),
  DraftAttachment.sniff('second.png', _png(2)),
  DraftAttachment.sniff('third.png', _png(3)),
];

ImageAttachment _stored(int index) =>
    ImageAttachment(attachmentId: 'image-$index', mediaType: 'image/png', name: 'stored-$index.png');

Future<void> _swipe(WidgetTester tester, {required bool next}) async {
  await tester.drag(find.byType(ImagePager), Offset(next ? -300 : 300, 0));
  final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
  // Theme changes may replace ScrollPosition while absorbing its animation.
  for (var frame = 0; frame < 120 && pages.position.isScrollingNotifier.value; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(pages.position.isScrollingNotifier.value, isFalse);
  await pumpFrames(tester);
}

void _expectPage(int current, int total) {
  expect(find.byKey(const ValueKey('attachment-gallery-page')), findsOneWidget);
  expect(find.text('$current / $total'), findsOneWidget);
}

List<MethodCall> _mockGallery(WidgetTester tester) {
  final calls = <MethodCall>[];
  const channel = MethodChannel('dsh/media');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return 'Pictures/DSH Go/saved.png';
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  return calls;
}

void main() {
  setUpAll(loadTestFonts);

  for (final pending in [false, true]) {
    testWidgets('${pending ? 'pending message' : 'composer'} groups images, filters files and starts at second', (
      tester,
    ) async {
      usePhoneView(tester);
      final drafts = _drafts();
      final source = pending ? SentAttachments.pending(drafts) : ComposerTray(items: drafts, onRemove: (_) {});
      await tester.pumpWidget(testApp(Scaffold(body: Center(child: source))));
      await pumpFrames(tester);
      expect(find.text('notes.txt'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('图片').at(1));
      await pumpFrames(tester);
      _expectPage(2, 3);
      expect(find.text('second.png'), findsOneWidget);
      expect(tester.widget<ImagePager>(find.byType(ImagePager)).initialPage, 1);
      expect(tester.widget<ImagePager>(find.byType(ImagePager)).itemCount, 3);
      final picture = tester.widget<Image>(find.byKey(const ValueKey('attachment-gallery-image-1')));
      expect(picture.image, isA<MemoryImage>());
      expect((picture.image as MemoryImage).bytes, orderedEquals(drafts[2].bytes));
      expect(find.byWidgetPredicate((widget) => widget is Hero && widget.tag == 'draft-${drafts[2].id}'), findsWidgets);

      await _swipe(tester, next: false);
      _expectPage(1, 3);
      expect(find.text('first.png'), findsOneWidget);
      await _swipe(tester, next: true);
      _expectPage(2, 3);
      await _swipe(tester, next: true);
      _expectPage(3, 3);
      expect(find.text('third.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stored gallery counts loading pictures and keeps a failed page navigable', (tester) async {
    usePhoneView(tester);
    final pending = Completer<Uint8List>();
    final requests = <String>[];
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SentAttachments.echoed(
            sessionId: 'session',
            images: [for (var i = 0; i < 3; i++) _stored(i)],
            files: const [FileAttachment(name: 'notes.txt')],
          ),
        ),
        overrides: [
          sessionImageProvider.overrideWith((ref, key) {
            requests.add(key.$2.attachmentId);
            return key.$2.attachmentId == 'image-2' ? pending.future : Future.value(_png(key.$2.attachmentId == 'image-0' ? 1 : 2));
          }),
        ],
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel('图片').at(1));
    await pumpFrames(tester);
    _expectPage(2, 3);
    expect(find.text('stored-1.png'), findsOneWidget);
    await _swipe(tester, next: true);
    _expectPage(3, 3);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    pending.completeError(StateError('missing attachment'));
    await pumpFrames(tester);
    _expectPage(3, 3);
    expect(find.byKey(const ValueKey('attachment-gallery-error-2')), findsOneWidget);
    expect(find.byIcon(AppIcons.imageBroken), findsWidgets);
    await _swipe(tester, next: false);
    _expectPage(2, 3);
    expect(requests.toSet(), {'image-0', 'image-1', 'image-2'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored lazy pages survive their source bubble unmounting', (tester) async {
    usePhoneView(tester);
    var visible = true;
    late StateSetter updateSource;
    final requests = <String, int>{};
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              updateSource = setState;
              return visible
                  ? SentAttachments.echoed(
                      sessionId: 'session',
                      images: [for (var i = 0; i < 5; i++) _stored(i)],
                      files: const [],
                    )
                  : const SizedBox();
            },
          ),
        ),
        overrides: [
          sessionImageProvider.overrideWith((ref, key) async {
            final count = requests.update(key.$2.attachmentId, (count) => count + 1, ifAbsent: () => 1);
            if (key.$2.attachmentId == 'image-4' && count > 1) throw StateError('attachment disappeared');
            return _png(int.parse(key.$2.attachmentId.split('-').last));
          }),
        ],
      ),
    );
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(SentAttachments)), listen: false);
    await tester.tap(find.bySemanticsLabel('图片').at(1));
    await pumpFrames(tester);
    _expectPage(2, 5);
    updateSource(() => visible = false);
    await pumpFrames(tester);
    expect(find.byType(SentAttachments), findsNothing);
    container.invalidate(sessionImageProvider(('session', _stored(4))));
    await pumpFrames(tester);

    for (var i = 0; i < 3; i++) {
      await _swipe(tester, next: true);
    }
    _expectPage(5, 5);
    expect(requests['image-4'], greaterThanOrEqualTo(2));
    expect(find.byKey(const ValueKey('attachment-gallery-error-4')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final stored in [false, true]) {
    testWidgets('${stored ? 'stored' : 'draft'} save button and long-press menu keep the current original picture', (
      tester,
    ) async {
      usePhoneView(tester);
      final saves = _mockGallery(tester);
      final drafts = _drafts();
      final images = drafts.where((draft) => draft.isImage).toList();
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: stored
                ? SentAttachments.echoed(
                    sessionId: 'session',
                    images: [
                      for (var i = 0; i < images.length; i++)
                        ImageAttachment(attachmentId: '$i', mediaType: 'image/png', name: images[i].name),
                    ],
                    files: const [],
                  )
                : ComposerTray(items: drafts, onRemove: (_) {}),
          ),
          overrides: [sessionImageProvider.overrideWith((ref, key) async => images[int.parse(key.$2.attachmentId)].bytes)],
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.bySemanticsLabel('图片').at(1));
      await pumpFrames(tester);
      await tester.tap(find.byTooltip('保存到相册'));
      await pumpFrames(tester);
      expect(saves, hasLength(1));
      expect((saves[0].arguments as Map)['name'], 'second.png');
      expect((saves[0].arguments as Map)['bytes'], orderedEquals(drafts[2].bytes));

      await _swipe(tester, next: true);
      _expectPage(3, 3);
      expect(find.byTooltip('保存到相册'), findsOneWidget, reason: 'saved tick belongs to the previous picture');
      await tester.longPress(find.byType(ImagePager));
      await pumpFrames(tester);
      expect(find.widgetWithText(SettingsTile, '保存到相册'), findsOneWidget);
      expect(find.text('third.png'), findsWidgets);
      await tester.tap(find.widgetWithText(SettingsTile, '保存到相册'));
      await pumpFrames(tester);
      expect(saves, hasLength(2));
      expect((saves[1].arguments as Map)['name'], 'third.png');
      expect((saves[1].arguments as Map)['bytes'], orderedEquals(drafts[3].bytes));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('single-image compatibility keeps double-tap and zoomed drags from closing', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openImageViewer(context, MemoryImage(_png(1)), heroTag: 'single', name: 'single.png'),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('attachment-gallery-page')), findsNothing);
    expect(find.text('single.png'), findsOneWidget);
    await tester.tap(find.byType(ImagePager));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(ImagePager));
    await pumpFrames(tester);
    expect(find.byType(ImagePager), findsOneWidget);
    await tester.fling(find.byType(ImagePager), const Offset(0, 300), 1600);
    await pumpFrames(tester);
    expect(find.byType(ImagePager), findsOneWidget);
    await tester.tap(find.byType(ImagePager));
    await pumpFrames(tester);
    expect(find.byType(ImagePager), findsOneWidget, reason: 'zoomed image taps do not close the route');
    await tester.tap(find.byIcon(AppIcons.close));
    await pumpFrames(tester);
    expect(find.byType(ImagePager), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
