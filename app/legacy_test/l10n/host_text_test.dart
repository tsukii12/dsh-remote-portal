import 'package:dsh_app/l10n/host_text.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reasons = {'zh-CN': '需要联网', 'zh-Hans': '简体备用说明', 'zh': '中文备用说明', 'en': 'Network access is required'};

  test('English approval prefers the host English reason over Chinese', () {
    expect(localizedHostText(reasons, locale: 'en'), 'Network access is required');
    expect(localizedHostText(reasons, locale: 'en_US'), 'Network access is required');
  });

  test('Chinese approval retains the existing Chinese fallback order', () {
    expect(localizedHostText(reasons, locale: 'zh'), '需要联网');
    expect(localizedHostText(reasons, locale: 'zh_CN'), '需要联网');
    expect(localizedHostText({'zh-Hans': '简体', 'zh': '中文', 'en': 'English'}, locale: 'zh_CN'), '简体');
    expect(localizedHostText({'zh': '中文', 'en': 'English'}, locale: 'zh_CN'), '中文');
  });

  test('the generated Chinese instance and app locale select the same reason', () {
    final generatedLocale = lookupL10n(AppLocale.zhCN).localeName;
    expect(generatedLocale, 'zh');
    expect(localizedHostText(reasons, locale: generatedLocale), '需要联网');
    expect(
      localizedHostText(reasons, locale: generatedLocale),
      localizedHostText(reasons, locale: AppLocale.zhCN.toLanguageTag()),
    );
  });

  test('a blank preferred value does not suppress another host reason', () {
    expect(localizedHostText({'en': ' \n ', 'zh-CN': '中文'}, locale: 'en'), '中文');
    expect(localizedHostText({'en': null}, locale: 'en', fallback: ' original '), 'original');
  });

  test('missing translations preserve the original host reason', () {
    expect(localizedHostText({}, locale: 'en', fallback: ' original '), 'original');
    expect(localizedHostText({}, locale: 'zh_CN'), isNull);
    expect(localizedHostText({}, locale: 'en', fallback: '  '), isNull);
  });

  test('exact locale precedes its language without changing stored messages', () {
    final text = {'es-MX': 'Variante', 'es': 'General', 'en': 'Fallback'};
    expect(localizedHostText(text, locale: 'es_MX'), 'Variante');
    expect(localizedHostText(text, locale: 'es_AR'), 'General');
    expect(text, {'es-MX': 'Variante', 'es': 'General', 'en': 'Fallback'});
  });

  test('unknown locales fall back to English, then Chinese, then original', () {
    expect(localizedHostText(reasons, locale: 'ru'), 'Network access is required');
    expect(localizedHostText({'zh': '中文'}, locale: 'ru', fallback: 'original'), '中文');
  });
}
