// Finite CC-only port of SillyTavern 1.19.0 public/script.js cleanUpMessage,
// scripts/power-user.js fixMarkdown(false), and scripts/utils.js
// trimToEndSentence. Source commit 7e8663cd9c184a550b37238218bdd32c6efc68e9
// (AGPL-3.0). The engine supplies each prescribed macro/regex call; this file
// never captures state, retries a callback, or processes an instruct/TC branch.
import '../js_string.dart';

final class StOutputCleanupOptions {
  const StOutputCleanupOptions({
    required this.collapseNewlines,
    required this.trimSentences,
    required this.trimSpaces,
    required this.allowUserName,
    required this.allowCharacterName,
    required this.fixMarkdown,
    required this.disableGroupTrimming,
    required this.userPromptBias,
  });
  final bool collapseNewlines;
  final bool trimSentences;
  final bool trimSpaces;
  final bool allowUserName;
  final bool allowCharacterName;
  final bool fixMarkdown;
  final bool disableGroupTrimming;
  final String userPromptBias;
}

/// One synchronous cleanup call. Name getters remain lazy so an actor is only
/// required at an actual name-consuming branch, including the global line-head
/// removal which deliberately does not depend on [trimNames].
String stCleanUpMessage(
  String decoded, {
  required StOutputCleanupOptions options,
  required String Function(String) expand,
  required List<String> Function() stoppingStrings,
  required String Function(String) outputRegex,
  required String Function() userName,
  required String Function() characterName,
  required List<String> Function() groupNames,
  required bool isGroup,
  required bool includeUserPromptBias,
  required bool displayIncompleteSentences,
  required bool trimNames,
  required bool trimWrongNames,
}) {
  if (decoded.isEmpty) return '';
  var text = decoded;
  if (includeUserPromptBias && options.userPromptBias.isNotEmpty) {
    text = '${expand(options.userPromptBias)}$text';
  }
  for (final stop in stoppingStrings()) {
    for (var length = stop.length; length > 0; length--) {
      if (text.endsWith(stop.substring(0, length))) {
        text = text.substring(0, text.length - length);
        break;
      }
    }
  }
  text = outputRegex(text);
  if (options.collapseNewlines) text = stCollapseNewlines(text);
  text = _trimLineEnds(text);
  if (trimWrongNames && !options.allowUserName) {
    final name = userName();
    if (name.isNotEmpty) {
      if (text.startsWith('$name:')) text = '';
      final index = text.indexOf('\n$name:');
      if (index >= 0) text = text.substring(0, index);
    }
  }
  final endOfText = text.indexOf('<|endoftext|>');
  if (endOfText >= 0) text = text.substring(0, endOfText);
  if (isGroup && !options.disableGroupTrimming) {
    final current = characterName();
    for (final name in groupNames()) {
      if (name == current) continue;
      final index = text.startsWith('$name:') ? 0 : text.indexOf('\n$name:');
      if (index >= 0) text = text.substring(0, index);
    }
  }
  if (!options.allowCharacterName) {
    final name = characterName();
    final pattern = RegExp('(^|\n)${RegExp.escape(name)}:$_jsSpace*');
    text = text.replaceAllMapped(pattern, (match) => match.group(1)!);
  }
  if (options.fixMarkdown) text = stFixMarkdown(text);
  if (trimNames && !options.allowCharacterName) {
    final name = characterName();
    if (name.isNotEmpty && text.startsWith('$name:')) {
      text = trimStartJsWhitespace(text.substring(name.length + 1));
    }
  }
  if (!displayIncompleteSentences && options.trimSentences) {
    text = stTrimToEndSentence(text);
  }
  return options.trimSpaces ? trimJsWhitespace(text) : text;
}

// Explicit ECMAScript whitespace: Dart's native trim additionally removes NEL.
const _jsSpace = r'[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]';
const _markdownSpace = r'[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000\ufeff]';

String stCollapseNewlines(String text) => text.replaceAll(RegExp(r'\n+'), '\n');

String _trimLineEnds(String text) {
  // Explicit JS /[^\S\r\n]+$/gm, including its LS/PS whitespace members.
  return text.replaceAll(
    RegExp(
      r'[\u0009\u000b\u000c\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
      multiLine: true,
    ),
    '',
  );
}

String stFixMarkdown(String text) {
  final matches = RegExp(r'([*_]{1,2})([\s\S]*?)\1', multiLine: true).allMatches(text).toList(growable: false);
  final spaces = RegExp('(\\*|_)($_markdownSpace+)|($_markdownSpace+)(\\*|_)');
  var result = text;
  for (final match in matches.reversed) {
    final replacement = match
        .group(0)!
        .replaceAllMapped(spaces, (part) => '${part.group(1) ?? ''}${part.group(4) ?? ''}');
    result = result.replaceRange(match.start, match.end, replacement);
  }
  return result;
}

final _emoji = RegExp(r'(\p{Emoji_Presentation}|\p{Extended_Pictographic})', unicode: true);
const _sentencePunctuation = <String>{
  '.',
  '!',
  '?',
  '*',
  '"',
  ')',
  '}',
  '`',
  ']',
  r'$',
  '。',
  '！',
  '？',
  '”',
  '）',
  '】',
  '’',
  '」',
  '_',
};

String stTrimToEndSentence(String text) {
  if (text.isEmpty) return '';
  final characters = text.runes.toList(growable: false);
  for (var i = characters.length - 1; i >= 0; i--) {
    final character = String.fromCharCode(characters[i]);
    final emoji = _emoji.hasMatch(character);
    if (_sentencePunctuation.contains(character) || emoji) {
      final last = !emoji && i > 0 && isJsWhitespace(characters[i - 1]) ? i - 1 : i;
      return trimEndJsWhitespace(String.fromCharCodes(characters.take(last + 1)));
    }
  }
  return trimEndJsWhitespace(text);
}

/// Fixed removeReasoningFromString: only a leading complete literal pair.
String stRemoveInlineReasoning(
  String text, {
  required bool autoParse,
  required String prefix,
  required String suffix,
  required bool trimSpaces,
}) {
  if (!autoParse || prefix.isEmpty || suffix.isEmpty) return text;
  final pattern = RegExp('^$_jsSpace*?${RegExp.escape(prefix)}[\\s\\S]*?${RegExp.escape(suffix)}');
  final match = pattern.firstMatch(text);
  if (match == null) return text;
  final result = text.substring(match.end);
  return trimSpaces ? trimJsWhitespace(result) : result;
}
