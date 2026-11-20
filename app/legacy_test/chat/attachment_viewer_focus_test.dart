import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/image_gallery.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Rig {
  final input = TextEditingController(text: '未发送的草稿');
  final focus = FocusNode();
  late BuildContext context;

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Builder(
            builder: (context) {
              this.context = context;
              return Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SentAttachments.echoed(
                        sessionId: 'synthetic-session',
                        images: [
                          ImageAttachment(
                            attachmentId: 'synthetic-image',
                            mediaType: 'image/png',
                            name: 'synthetic.png',
                            width: 120,
                            height: 120,
                          ),
                        ],
                        files: const [],
                      ),
                    ),
                  ),
                  Composer(
                    controller: input,
                    focusNode: focus,
                    connected: true,
                    running: false,
                    busy: false,
                    onSend: () {},
                    onStop: () {},
                  ),
                ],
              );
            },
          ),
        ),
        overrides: [sessionImageProvider.overrideWith((ref, key) async => tinyPng)],
      ),
    );
    await pumpFrames(tester);
  }

  void dispose() {
    focus.dispose();
    input.dispose();
  }
}

void main() {
  for (final hiddenKeyboard in [false, true]) {
    for (final systemBack in [false, true]) {
      testWidgets('attachment viewer ${systemBack ? 'system back' : 'close'} keeps input inactive after '
          '${hiddenKeyboard ? 'keyboard-only dismissal' : 'explicit unfocus'}', (tester) async {
        final rig = _Rig();
        addTearDown(rig.dispose);
        await rig.pump(tester);
        await tester.showKeyboard(find.byType(TextField));
        expect(rig.focus.hasFocus, isTrue);
        if (hiddenKeyboard) {
          // A hidden Android keyboard need not clear Flutter's focused child.
          tester.testTextInput.hide();
        } else {
          rig.focus.unfocus();
        }
        await tester.pump();
        expect(tester.testTextInput.isVisible, isFalse);
        expect(rig.focus.hasFocus, hiddenKeyboard);

        await tester.tap(find.bySemanticsLabel('图片'));
        await pumpFrames(tester);
        expect(find.byType(ImagePager), findsOneWidget);
        expect(rig.focus.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byIcon(AppIcons.close));
        }
        await pumpFrames(tester);

        expect(find.byType(ImagePager), findsNothing);
        expect(
          {'focused': rig.focus.hasFocus, 'keyboardVisible': tester.testTextInput.isVisible, 'draft': rig.input.text},
          {'focused': false, 'keyboardVisible': false, 'draft': '未发送的草稿'},
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('an empty attachment gallery does not change composer focus', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.pump(tester);
    await tester.showKeyboard(find.byType(TextField));

    await openAttachmentGallery(rig.context, const []);
    await tester.pump();

    expect(rig.focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byType(ImagePager), findsNothing);
  });
}
