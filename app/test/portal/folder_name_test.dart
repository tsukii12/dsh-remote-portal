import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new folder names are literal paths, not autocorrected prose', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await askFolderName(context, parentName: 'fixture');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    await tester.enterText(find.byType(TextField), 'yuremote-m2-picker-smoke');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(picked, 'yuremote-m2-picker-smoke');
  });
}
