import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/providers/subscription_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in AppLocale.supported) {
    group('prompt title in $locale', () {
      final previousLocale = AppLocale.current;

      setUp(() {
        AppLocale.use(locale);
      });
      tearDown(() => AppLocale.use(previousLocale));

      test('the bridge full-address message asks for a redirect URL', () {
        const message = '在浏览器里登录后，把地址栏里的完整网址复制下来，粘贴到这里';
        expect(promptTitle(message), appL10n.engineSubscriptionPasteRedirect);
      });

      test('authorization code wording keeps the code title', () {
        expect(promptTitle('Paste the authorization code'), appL10n.engineSubscriptionPasteCode);
      });

      test('English redirect wording keeps the redirect title', () {
        expect(promptTitle('Paste the redirect URL'), appL10n.engineSubscriptionPasteRedirect);
      });

      test('no prompt wording keeps the code default', () {
        expect(promptTitle(null), appL10n.engineSubscriptionPasteCode);
      });
    });
  }
}
