import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/bots/bot_file_text_body.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;

void main() {
  setUpAll(loadTestFonts);
  for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
    testWidgets('${locale.toLanguageTag()} renders the grouped partial text count', (tester) async {
      final text = 'x' * 200000;
      final value = DsBotFileText.fromJson({'text': text, 'whole': false});
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Localizations(
            locale: locale,
            delegates: L10n.localizationsDelegates,
            child: Scaffold(
              body: SingleChildScrollView(child: BotFileTextBody(value: value)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text(locale.languageCode == 'zh' ? '仅显示前 200,000 个字符' : 'Showing the first 200,000 characters'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
