import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/share_code_widgets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/fake_engine.dart';
import 'support/sheet_support.dart';

void main() {
  testWidgets('view instructions and skill files without selecting them; checks stay aligned', (tester) async {
    usePhoneSurface(tester);
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    const profile = ProfileShare(
      skills: [
        SharedSkill(name: 'quick', files: {'extra.txt': '另一份内容', 'SKILL.md': '技能全文'}),
      ],
      agentsMd: '偏好第一行\n偏好最后一行',
    );
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: SheetHost(open: (c) => showShareImportSheet(c, profile)),
        overrides: shareOverrides(
          net: FakeShareNet(),
          targets: [localTarget(DshClient.withCarrier(FakeEngine()))],
          fs: fs,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-import-integrity')), findsNothing);
    final checks = find.byType(ShareCheck);
    expect(checks, findsNWidgets(2));
    final right = tester.getRect(checks.first).right;
    for (var i = 0; i < 2; i++) {
      final check = checks.at(i);
      final row = find.ancestor(of: check, matching: find.byType(ListPageRow)).first;
      expect(tester.widget<ShareCheck>(check).value, isFalse);
      expect(tester.getRect(check).right, closeTo(right, 0.01));
      expect(tester.getRect(check).center.dy, closeTo(tester.getRect(row).center.dy, 0.01));
    }
    final view = find.byKey(const ValueKey('share-view-agents-md'));
    expect(tester.getSize(view), const Size(44, 44));
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == profile.agentsMd), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-view-skill:quick')));
    await tester.pumpAndSettle();
    final first = tester.getRect(find.byKey(const ValueKey('share-file-SKILL.md')));
    final second = tester.getRect(find.byKey(const ValueKey('share-file-extra.txt')));
    expect(first.top, lessThan(second.top));
    await tester.tap(find.byKey(const ValueKey('share-file-SKILL.md')));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == '技能全文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
