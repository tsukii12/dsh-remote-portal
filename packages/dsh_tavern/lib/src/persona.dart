// Persona precedence and description placement follow SillyTavern 1.19.0:
// public/scripts/personas.js and public/scripts/openai.js, commit
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
import 'dart:convert';

/// ST's numeric persona-description positions. Only [inPrompt] belongs in the
/// personaDescription marker. Other placements have their own injection path.
abstract final class PersonaDescriptionPosition {
  static const inPrompt = 0;
  static const topAuthorNote = 2;
  static const bottomAuthorNote = 3;
  static const atDepth = 4;
  static const none = 9;
}

/// An immutable user persona. Description macros remain unevaluated here.
/// [avatarPath] is a reference owned by the caller; deleting a persona does not
/// remove that file. Unknown JSON fields survive read/modify/write operations.
class TavernPersona {
  factory TavernPersona({
    required String id,
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) => TavernPersona.fromJson({
    'id': id,
    'name': name,
    'description': description,
    'avatarPath': avatarPath,
    'descriptionPosition': descriptionPosition,
  });

  TavernPersona._(this._json);

  factory TavernPersona.fromJson(Map<String, Object?> json) {
    final data = _copy(json);
    final id = data['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Persona id must be a non-empty string.');
    }
    if (data['name'] is! String) {
      throw const FormatException('Persona name must be a string.');
    }
    if (data['description'] != null && data['description'] is! String) {
      throw const FormatException('Persona description must be a string.');
    }
    if (data['avatarPath'] != null && data['avatarPath'] is! String) {
      throw const FormatException('Persona avatarPath must be a string or null.');
    }
    final position = data['descriptionPosition'] ?? PersonaDescriptionPosition.inPrompt;
    if (position is! num || !position.isFinite || position != position.truncateToDouble()) {
      throw const FormatException('Persona descriptionPosition must be an integer.');
    }
    data['description'] ??= '';
    // Fixed ST migrates its deprecated AFTER_CHAR (1) placement to IN_PROMPT.
    data['descriptionPosition'] = position == 1 ? PersonaDescriptionPosition.inPrompt : position.toInt();
    return TavernPersona._(data);
  }

  final Map<String, Object?> _json;

  String get id => _json['id']! as String;
  String get name => _json['name']! as String;
  String get description => _json['description']! as String;
  String? get avatarPath => _json['avatarPath'] as String?;
  int get descriptionPosition => _json['descriptionPosition']! as int;
  bool get inPrompt => descriptionPosition == PersonaDescriptionPosition.inPrompt;

  Map<String, Object?> toJson() => _copy(_json);

  /// Null means unchanged, except [clearAvatar] explicitly removes the path.
  TavernPersona copyWith({
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) {
    if (clearAvatar && avatarPath != null) {
      throw ArgumentError('Provide avatarPath or clearAvatar, not both.');
    }
    return TavernPersona.fromJson({
      ..._json,
      'name': ?name,
      'description': ?description,
      if (avatarPath != null || clearAvatar) 'avatarPath': clearAvatar ? null : avatarPath,
      'descriptionPosition': ?descriptionPosition,
    });
  }

  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, Object?>;
}

enum PersonaSelectionSource { chat, globalDefault, none }

/// An effective persona snapshot for a new turn. A null [boundPersonaId] means
/// the chat inherits its global default; dangling ids are treated as unbound.
class PersonaSelection {
  const PersonaSelection({
    required this.persona,
    required this.source,
    required this.boundPersonaId,
    required this.defaultPersonaId,
  });

  final TavernPersona? persona;
  final PersonaSelectionSource source;
  final String? boundPersonaId;
  final String? defaultPersonaId;
}
