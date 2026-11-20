import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

void main() {
  testWidgets('every inventory status dot shares the right edge and row centre', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ListPageCard(
            children: [
              for (final status in InventoryStatus.values)
                InventoryRow(
                  item: InventoryItem(
                    entryId: status.name,
                    moduleName: 'private-${status.name}',
                    title: status.name,
                    status: status,
                    description: status.index.isEven ? '描述' : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final rows = find.byType(InventoryRow);
    for (var i = 0; i < rows.evaluate().length; i++) {
      final row = tester.getRect(rows.at(i));
      final dot = tester.getRect(find.descendant(of: rows.at(i), matching: find.byType(AnimatedStatusDot)));
      expect(dot.right, closeTo(row.right - 16, 0.01));
      expect(dot.center.dy, closeTo(row.center.dy, 0.01));
      expect(dot.size, const Size.square(8));
    }
    expect(find.byType(StatusChip), findsNothing);
    expect(find.textContaining('private-'), findsNothing);
  });
}
