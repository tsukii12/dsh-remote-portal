/// Selects text already supplied by the host; never translates or executes it.
///
/// The exact locale and its language come first, then the app's existing
/// English/Chinese fallbacks. Blank values do not hide a useful fallback.
/// Callers keep their own display, truncation and credential masking rules.
String? localizedHostText(Map<String, String?> text, {required String locale, String? fallback}) {
  final tag = locale.replaceAll('_', '-');
  final language = tag.split('-').first.toLowerCase();
  final keys = <String>{
    // gen-l10n names the current Chinese instance 'zh', whereas the app
    // locale is zh_CN. Both must retain the same Simplified Chinese order.
    if (tag != 'zh') tag,
    if (language == 'zh') ...['zh-CN', 'zh-Hans', 'zh', 'en'] else ...[language, 'en', 'zh-CN', 'zh-Hans', 'zh'],
  };
  for (final key in keys) {
    final value = text[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final value = fallback?.trim();
  return value == null || value.isEmpty ? null : value;
}
