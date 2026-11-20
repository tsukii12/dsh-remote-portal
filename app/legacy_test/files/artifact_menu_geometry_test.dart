import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

void main() {
  testWidgets('artifact menu title and action group share the 20 gutter', (tester) async {
    usePhoneView(tester);
    const artifact = Artifact(path: '/root/report.md', origin: ArtifactOrigin.delivered, turn: 1);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showArtifactMenu(context, artifact: artifact, canFetch: false),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('report.md'));
    final group = tester.getRect(
      find.descendant(of: find.byType(SheetGroup).first, matching: find.byType(GlassSurface)).first,
    );
    expect(title.left, closeTo(20, 0.01));
    expect(find.byType(SheetDragHandle), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(title.left, closeTo(group.left, 0.01));
    expect(tester.takeException(), isNull);
  });
}
