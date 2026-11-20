import 'package:dsh_app/ui/chat/composer_toast.dart';
import 'package:dsh_app/ui/common/brief_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Show = void Function(BuildContext context, String text);

Future<void> _page(WidgetTester tester, _Show show) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating)),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              for (final text in ['first', 'middle', 'latest'])
                TextButton(onPressed: () => show(context, text), child: Text('show $text')),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _burst(WidgetTester tester) async {
  await tester.tap(find.text('show first'));
  await tester.pumpAndSettle();
  expect(find.text('first'), findsOneWidget);
  // Both callbacks arrive while the current notice is still reversing.
  await tester.tap(find.text('show middle'));
  await tester.tap(find.text('show latest'));
  await tester.pumpAndSettle();
}

void main() {
  final shows = <String, _Show>{
    'brief confirmation': showBriefNotice,
    'composer toast': (context, text) => showComposerToast(context, text, composerHeight: 60),
  };
  for (final MapEntry(:key, :value) in shows.entries) {
    testWidgets('$key keeps only the latest message during exit animation', (tester) async {
      await _page(tester, value);
      await _burst(tester);

      expect(find.text('latest'), findsOneWidget);
      expect(find.text('middle'), findsNothing);
    });

    testWidgets('$key burst does not leave another notice after its duration', (tester) async {
      await _page(tester, value);
      await _burst(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('$key single notice still expires (control)', (tester) async {
      await _page(tester, value);
      await tester.tap(find.text('show first'));
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });
  }
}
