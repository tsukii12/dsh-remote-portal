// Machine translation of expanded reasoning (DSH's optional
// `dsh-experimental-cot-translation-bundle`). The thinking view asks
// [cotTranslationProvider] whether the bundle is on, then drives one
// [ReasoningTranslation] per reasoning block.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';

/// The app's interface language, the target of `auto`.
String get reasoningUiLanguage => AppLocale.current.languageCode;

/// `cotTranslation/limits` of the active host; null while the bundle is off,
/// its provider can't take requests, or nothing is connected. Read only while
/// a thinking block is open (auto-dispose), so a bundle switched on later
/// shows up on the next open.
final cotTranslationProvider = FutureProvider.autoDispose<CotTranslationLimits?>((ref) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return null;
  try {
    final limits = await client.cotTranslationLimits();
    return limits.usable ? limits : null;
  } catch (_) {
    return null;
  }
});

/// Translates one fragment with [limits]' accepted provider and language.
typedef ReasoningTranslator = Future<String> Function(
  String text, {
  required CotTranslationLimits limits,
  String? sessionId,
});

/// The Host call behind [ReasoningTranslator] (a seam for tests).
final reasoningTranslatorProvider = Provider<ReasoningTranslator?>((ref) {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return null;
  return (text, {required limits, sessionId}) => client.translateReasoning(
    text,
    targetLanguage: limits.targetFor(reasoningUiLanguage),
    provider: limits.provider,
    sessionId: sessionId,
  );
});

/// Whether [text] is worth translating into [target]: reasoning already in
/// the target script (Chinese into `zh`, Latin into the other interface
/// languages) is not.
bool reasoningNeedsTranslation(String text, String target) {
  // Kana, Hangul, Cyrillic and other scripts belong to neither interface
  // language. Keep an explicit translation choice for such text.
  if (_reasoningOtherLetters.hasMatch(text)) return true;
  // A Han character carries about as much as a Latin word: identifiers in
  // Chinese reasoning don't make it foreign, nor a quoted Chinese word in
  // English. This is only an offer heuristic: Han-only Japanese cannot be
  // distinguished from Chinese by script alone.
  final cjk = _reasoningHan.allMatches(text).length;
  final words = _reasoningLatinWords.allMatches(text).length;
  return target.toLowerCase().startsWith('zh') ? words > cjk : cjk > words;
}

final _reasoningHan = RegExp(r'\p{Script=Han}', unicode: true);
final _reasoningLatinWords = RegExp(r'\p{Script=Latin}+', unicode: true);
// A lone Greek letter (θ, α) or a letterlike symbol (µ, ℝ) is notation, not a
// language; Greek words still are.
final _reasoningOtherLetters = RegExp(
  r'(?!\p{Script=Han}|\p{Script=Latin}|\p{Script=Greek}|\p{Script=Common})\p{L}|\p{Script=Greek}{2,}',
  unicode: true,
);

/// Sequential paragraph translation for one reasoning block, as the official
/// client does it: complete paragraphs (and request-sized pieces of long ones)
/// go out one at a time, the still-growing tail stays original, results are
/// cached by fragment text, and a failure keeps the original until [retry].
class ReasoningTranslation extends ChangeNotifier {
  ReasoningTranslation({required this.maxTextChars, required this.translate});

  final int maxTextChars;
  final Future<String> Function(String text) translate;

  final Map<String, String> _cache = {};
  List<ReasoningFragment> _fragments = const [];
  bool _pending = false;
  bool _failed = false;
  bool _disposed = false;

  /// The display text: translated where available, original elsewhere.
  String get text =>
      [for (final f in _fragments) '${f.complete ? _cache[f.text] ?? f.text : f.text}${f.suffix}'].join();

  bool get pending => _pending;
  bool get failed => _failed;

  /// Something has been translated already.
  bool get hasTranslation => _cache.isNotEmpty;

  /// Adopts the current reasoning and queues newly completed fragments.
  void update(String source, {required bool running}) {
    if (_disposed) return;
    _fragments = reasoningFragments(source, running: running, maxTextChars: maxTextChars);
    notifyListeners();
    unawaited(_run());
  }

  void retry() {
    if (_disposed) return;
    _failed = false;
    unawaited(_run());
  }

  ReasoningFragment? _next() {
    for (final f in _fragments) {
      if (f.complete && f.text.trim().isNotEmpty && !_cache.containsKey(f.text)) {
        return f;
      }
    }
    return null;
  }

  Future<void> _run() async {
    if (_pending || _failed || _disposed) return;
    var next = _next();
    if (next == null) return;
    _pending = true;
    notifyListeners();
    try {
      while (next != null) {
        final translated = await translate(next.text);
        if (_disposed) return;
        _cache[next.text] = translated;
        notifyListeners();
        next = _next();
      }
    } catch (_) {
      if (!_disposed) _failed = true;
    } finally {
      _pending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
