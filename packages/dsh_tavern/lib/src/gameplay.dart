import 'gameplay_packs.dart';

/// A real character and, optionally, one of its real chat contexts.
/// In a group the character may be the host or any actual roster member.
final class TavernGameplayContext {
  const TavernGameplayContext({required this.characterId, this.chatId});

  final String characterId;
  final String? chatId;
}

enum TavernGameplayScope { global, character, chat }

/// One proposed scope, in binding priority order. This does not save a binding.
final class TavernPackScopePreview {
  const TavernPackScopePreview({required this.scope, required this.bindings, this.targetId});

  final TavernGameplayScope scope;
  final String? targetId;
  final List<TavernPackBindingPreview> bindings;
}

/// A proposed stable binding identity and its explicitly chosen version.
/// Aliases name another bindingId in this same proposed vector.
final class TavernPackBindingPreview {
  const TavernPackBindingPreview({
    required this.bindingId,
    required this.packRef,
    this.enabled = true,
    this.aliases = const {},
  });

  final String bindingId;
  final TavernPackVersionRef packRef;
  final bool enabled;
  final Map<String, String> aliases;
}

/// Owned preview data. No schema session, binding adoption, or state mutation
/// is performed. Definition diagnostics and composition conflicts are separate.
final class TavernGameplayResolution {
  const TavernGameplayResolution({
    required this.context,
    required this.hostCharacterId,
    required this.rawPresent,
    required this.raw,
    required this.effective,
    required this.sources,
    required this.fieldSources,
    required this.resources,
    required this.definitions,
    required this.conflicts,
    required this.effectiveConfigId,
    this.currentState,
  });

  final TavernGameplayContext context;
  final String hostCharacterId;

  /// The actual host card's original extension, including absence and null.
  final bool rawPresent;
  final Object? raw;
  final Object? effective;
  final List<Map<String, Object?>> sources;
  final List<Map<String, Object?>> fieldSources;

  /// The original legacy order with explicit proposed pack resource sources.
  /// This is a source plan; it does not allocate runtime book or entry IDs.
  final List<Map<String, Object?>> resources;
  final List<Map<String, Object?>> definitions;
  final List<Map<String, Object?>> conflicts;
  final ({
    Map<String, Object?> source,
    bool valueExists,
    Object? value,
    bool validated,
    List<Map<String, Object?>> issues,
  })?
  currentState;

  /// Identity of the captured configuration, not a saved adoption or CAS token.
  final String effectiveConfigId;
}
