import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('image viewer glass buttons retain app extensions from ${brightness.name}', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openImageViewer(context, MemoryImage(tinyPng), heroTag: 'image', name: 'photo.png'),
                child: const Text('Open'),
              ),
            ),
          ),
          brightness: brightness,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(GlassIconButton), findsNWidgets(2));
      expect(find.byType(GallerySaveButton), findsOneWidget);
      final context = tester.element(find.byType(GlassIconButton).first);
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(Theme.of(context).extension<DshSurfaces>(), isNotNull);
      expect(Theme.of(context).extension<DshColors>(), isNotNull);
      await tester.tap(find.byIcon(AppIcons.close));
      await tester.pumpAndSettle();
      expect(find.byType(GallerySaveButton), findsNothing);
    });
  }
}
