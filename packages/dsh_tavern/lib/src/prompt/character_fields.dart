// Adapted from SillyTavern public/script.js getCharacterCardFields (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import '../js_string.dart';
import 'prompt_types.dart';

/// ST's eager field snapshot, resolved before scanning world info and reused
/// for explicit prompt fields. Ordinary macro environments still create their
/// own lazy getters from the raw card. Inspection returns the completed result
/// rather than repeating either kind of expansion.
final class PreparedCharacterFields {
  const PreparedCharacterFields(this.values, this.persona, this.alternateGreetings);
  final Map<String, String> values;
  final String persona;
  final List<String> alternateGreetings;
  String operator [](String name) => values[name] ?? '';
}

/// The callback uses ST's baseChatReplace mode (replaceCharacterCard=false).
/// Raw card JSON remains untouched, including its whitespace and unknown keys.
PreparedCharacterFields prepareCharacterFields(
  Map<String, Object?> card, {
  String persona = '',
  required PromptExpansion expand,
}) {
  String base(Object? value) {
    final text = value is String ? trimJsWhitespace(value) : '';
    return text.isEmpty ? '' : expand(text, const {}).replaceAll('\r', '');
  }

  final values = <String, String>{};
  // Keep ST's eager getter access order, even for fields not eventually sent.
  for (final key in ['system_prompt', 'mes_example', 'description', 'personality']) {
    values[key] = base(card[key]);
  }
  final preparedPersona = base(persona);
  for (final key in ['scenario', 'post_history_instructions']) {
    values[key] = base(card[key]);
  }
  values['character_version'] = card['character_version'] as String? ?? '';
  final extensions = card['extensions'];
  final depthPrompt = extensions is Map<String, Object?> ? extensions['depth_prompt'] : null;
  values['charDepthPrompt'] = depthPrompt is Map<String, Object?> ? base(depthPrompt['prompt']) : '';
  for (final key in ['creator_notes', 'first_mes']) {
    values[key] = base(card[key]);
  }
  final greetings = card['alternate_greetings'];
  final alternate = greetings is List<Object?> ? greetings.map(base).toList() : <String>[];
  return PreparedCharacterFields(values, preparedPersona, alternate);
}
