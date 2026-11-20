/// Machine translation of expanded reasoning, the native counterpart of
/// `@deepseek-ai/dsh-experimental-client-ui-cot-translation` (Remote namespace
/// `cotTranslation`, mounted by the optional
/// `@deepseek-ai/dsh-experimental-cot-translation-bundle`).
///
/// * `cotTranslation/limits` — accepted provider and target language, the
///   eligible providers and the per-request text limit (no text sent);
/// * `cotTranslation/translate` — one displayed fragment through the accepted
///   provider. With a `sessionId` the translator stores the result in that
///   Session and later calls reuse it.
///
/// Both fail with a gateway error while the bundle is off. Verified against
/// DSH 0.2.1-rc.2 (`lib/index.js` host and `lib/client.js` of the package).
library;

import 'json.dart';
import 'session_api.dart';

/// `cotTranslation/limits`.
class CotTranslationLimits {
  const CotTranslationLimits({
    required this.maxTextChars,
    required this.provider,
    required this.targetLanguage,
    this.availableProviders = const [],
  });

  factory CotTranslationLimits.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final preferences = asMapOrEmpty(map['preferences']);
    final max = asInt(map['maxTextChars']) ?? 0;
    return CotTranslationLimits(
      maxTextChars: max > 0 ? max : 4000,
      provider: asString(preferences['provider']) ?? 'bing',
      targetLanguage: asString(preferences['targetLanguage']) ?? 'auto',
      availableProviders: asStringList(map['availableProviders']),
    );
  }

  /// Maximum UTF-16 length of one request.
  final int maxTextChars;

  /// Accepted provider (`bing`, `google`, `deepseek-account`,
  /// `deepseek-official`); requests never fall back to another.
  final String provider;

  /// BCP 47 code, or `auto` (follow the reader's UI language).
  final String targetLanguage;
  final List<String> availableProviders;

  /// The accepted provider can take requests now.
  bool get usable => availableProviders.isEmpty || availableProviders.contains(provider);

  /// The language to request for a reader whose UI language is [uiLanguage].
  String targetFor(String uiLanguage) => targetLanguage == 'auto' ? uiLanguage : targetLanguage;
}

/// One source fragment of a reasoning text and its untranslated separator.
class ReasoningFragment {
  const ReasoningFragment(this.text, this.suffix, {required this.complete});

  final String text;

  /// Whitespace kept verbatim after the fragment.
  final String suffix;

  /// Finished (followed by a paragraph break, or the stream is over): only
  /// complete fragments are translated, the growing tail stays original.
  final bool complete;
}

final RegExp _paragraphBreak = RegExp(r'\r?\n(?:[\t ]*\r?\n)+');

/// Splits [text] into paragraphs, and paragraphs longer than [maxTextChars]
/// into request-sized pieces at whitespace (never inside a surrogate pair),
/// preserving every separator. Same rules as the official client.
List<ReasoningFragment> reasoningFragments(String text, {required bool running, required int maxTextChars}) {
  final out = <ReasoningFragment>[];
  final limit = maxTextChars < 1 ? 1 : maxTextChars;
  var start = 0;
  final matches = _paragraphBreak.allMatches(text).toList();
  for (var i = 0; ; i++) {
    final match = i < matches.length ? matches[i] : null;
    final paragraph = text.substring(start, match?.start ?? text.length);
    // Keep the paragraph instead of copying its shrinking remainder per piece.
    var offset = 0;
    while (paragraph.length - offset > limit) {
      var cut = offset + limit;
      final unit = paragraph.codeUnitAt(cut - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) cut -= 1;
      final head = paragraph.substring(offset, cut);
      final ws = RegExp(r'\s+\S*$').firstMatch(head);
      if (ws != null && ws.start > 0) cut = offset + ws.start;
      final source = paragraph.substring(offset, cut);
      final lead = RegExp(r'\s+').matchAsPrefix(paragraph, cut);
      final suffix = lead?.group(0) ?? '';
      offset = cut + suffix.length;
      out.add(ReasoningFragment(source, suffix, complete: true));
    }
    out.add(ReasoningFragment(paragraph.substring(offset), match?.group(0) ?? '', complete: match != null || !running));
    if (match == null) return out;
    start = match.end;
  }
}

extension CotTranslationApi on DshClient {
  /// `cotTranslation/limits`; throws while the bundle is off.
  Future<CotTranslationLimits> cotTranslationLimits() async =>
      CotTranslationLimits.fromJson(await rpc.call('cotTranslation/limits'));

  /// `cotTranslation/translate`: [text] into [targetLanguage] through
  /// [provider] (must be the accepted one). Failures come back as
  /// `cotTranslation/failed` without details.
  Future<String> translateReasoning(
    String text, {
    required String targetLanguage,
    required String provider,
    String? sessionId,
  }) async {
    final value = await rpc.call('cotTranslation/translate', {
      'request': {'text': text, 'targetLanguage': targetLanguage, 'provider': provider, 'sessionId': ?sessionId},
    });
    return asString(value) ?? '';
  }
}
