import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  testWidgets('page title is a route heading and scrolled content has a backdrop veil', (tester) async {
    final semantics = tester.ensureSemantics();
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: AppPage.list(
          title: '设置',
          children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('正文 $i'))],
        ),
      ),
    );
    expect(tester.getSemantics(find.text('设置').first), isSemantics(label: '设置', isHeader: true, namesRoute: true));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropVeil), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.byType(BackdropVeil), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
