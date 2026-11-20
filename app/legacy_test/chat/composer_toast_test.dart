import 'package:dsh_app/ui/chat/composer_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpPage(WidgetTester tester, {VoidCallback? onAction}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating)),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              Expanded(
                child: Center(
                  child: TextButton(
                    onPressed: () => showComposerToast(
                      context,
                      'Inserted',
                      composerHeight: 120,
                      actionLabel: onAction == null ? null : 'Return',
                      onAction: onAction,
                    ),
                    child: const Text('go'),
                  ),
                ),
              ),
              const SizedBox(height: 120, child: TextField()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a plain composer toast clears the input and dismisses on tap', (tester) async {
    await _pumpPage(tester);
    final card = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first;
    final rect = tester.getRect(card);
    expect(rect.bottom, lessThan(tester.getRect(find.byType(TextField)).top));
    await tester.tapAt(rect.bottomRight - const Offset(2, 2));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
  });

  testWidgets('the input remains tappable while a composer toast is visible', (tester) async {
    await _pumpPage(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a composer action keeps its duration and still runs', (tester) async {
    var actions = 0;
    await _pumpPage(tester, onAction: () => actions++);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.duration, composerToastActionDuration);
    expect(bar.persist, isFalse);
    await tester.tap(find.text('Return'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(find.byType(SnackBar), findsNothing);
  });
}
