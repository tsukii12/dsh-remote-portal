import 'package:dsh_app/ui/common/search_capsule.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('search stays symmetric before and after text: $scale $brightness', (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        usePhoneView(tester);
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SearchCapsule(
                      controller: controller,
                      hint: '搜索任务',
                      onChanged: (_) {},
                      onClear: controller.clear,
                    ),
                  ),
                ),
              ),
            ),
            brightness: brightness,
          ),
        );
        final before = tester.getRect(find.byType(SearchCapsule));
        await tester.enterText(find.byType(TextField), '任务');
        await tester.pump();
        final after = tester.getRect(find.byType(SearchCapsule));
        expect(after, before);
        final search = tester.getCenter(find.byIcon(AppIcons.search));
        final clear = tester.getCenter(find.byIcon(AppIcons.clear));
        expect(search.dx - after.left, closeTo(after.right - clear.dx, 0.01));
        expect(search.dy, closeTo(after.center.dy, 0.01));
        expect(clear.dy, closeTo(after.center.dy, 0.01));
        expect(after.height, greaterThanOrEqualTo(44));
        await tester.tap(find.byIcon(AppIcons.clear));
        await tester.pump();
        expect(controller.text, isEmpty);
        expect(tester.getRect(find.byType(SearchCapsule)), before);
      });
    }
  }
}
