import 'package:dsh_app/ui/bots/bot_text_count.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['zh_CN', 'en']) {
    test('$locale groups the actual 200000 character prefix', () {
      expect(formatBotTextCount(200000, locale), '200,000');
      expect(formatBotTextCount(1234567, locale), '1,234,567');
      expect(formatBotTextCount(999, locale), '999');
      expect(formatBotTextCount(0, locale), '0');
    });
  }
}
