part of 'api.dart';

enum TavernChatKind { single, group }

enum TavernGroupActivation { natural, listOrder, randomPool, manual, director }

enum TavernGroupModelRole { main, helper }

class TavernGroupMember {
  const TavernGroupMember({
    required this.characterId,
    required this.talkativeness,
    required this.muted,
    required this.modelRole,
    this.available = true,
  });
  final String characterId;
  final double talkativeness;
  final bool muted;
  final TavernGroupModelRole modelRole;
  final bool available;
}

class TavernGroupChat {
  TavernGroupChat({
    required this.chatId,
    required this.title,
    required this.hostCharacterId,
    required List<TavernGroupMember> members,
    required this.activation,
    required this.maxSpeakersPerTurn,
    required this.allowSelfResponses,
  }) : members = List<TavernGroupMember>.unmodifiable(members);
  final String chatId;
  final String title;
  final String hostCharacterId;
  final List<TavernGroupMember> members;
  final TavernGroupActivation activation;
  final int maxSpeakersPerTurn;
  final bool allowSelfResponses;
}

enum TavernGroupPhase { preparing, ready, speaking, settling, finished }

enum TavernGroupEndReason { completed, noSpeakers, cancelled, failed }

class TavernGroupProgress {
  TavernGroupProgress({
    required this.chatId,
    required this.roundId,
    required this.startedAt,
    required this.phase,
    this.userNodeId,
    this.speakerCharacterId,
    this.replyNodeId,
    this.generationId,
    required List<String> plannedCharacterIds,
    required List<String> remainingCharacterIds,
    required List<String> completedNodeIds,
  }) : plannedCharacterIds = List<String>.unmodifiable(plannedCharacterIds),
       remainingCharacterIds = List<String>.unmodifiable(remainingCharacterIds),
       completedNodeIds = List<String>.unmodifiable(completedNodeIds);
  final String chatId;
  final String roundId;
  final DateTime startedAt;
  final TavernGroupPhase phase;
  final String? userNodeId;
  final String? speakerCharacterId;
  final String? replyNodeId;
  final String? generationId;
  final List<String> plannedCharacterIds;

  /// Unstarted actors only; excludes the current actor.
  final List<String> remainingCharacterIds;
  final List<String> completedNodeIds;
  String? get nextCharacterId => remainingCharacterIds.isEmpty ? null : remainingCharacterIds.first;
  int get remainingCount => remainingCharacterIds.length;
}

sealed class TavernGroupEvent {
  const TavernGroupEvent();
}

class TavernGroupStarted extends TavernGroupEvent {
  const TavernGroupStarted(this.progress);
  final TavernGroupProgress progress;
}

class TavernGroupProgressChanged extends TavernGroupEvent {
  const TavernGroupProgressChanged(this.progress);
  final TavernGroupProgress progress;
}

class TavernGroupMemberEvent extends TavernGroupEvent {
  const TavernGroupMemberEvent({required this.progress, required this.characterId, required this.event});
  final TavernGroupProgress progress;
  final String characterId;
  final TavernEvent event;
}

class TavernGroupSnapshot extends TavernGroupEvent {
  const TavernGroupSnapshot({required this.progress, this.message});
  final TavernGroupProgress progress;
  final TavernMessage? message;
}

class TavernGroupFinished extends TavernGroupEvent {
  const TavernGroupFinished({
    required this.chatId,
    required this.reason,
    this.progress,
    this.failure,
    this.code,
    this.detail,
    this.attemptedCharacterId,
    this.partial,
  });
  final String chatId;
  final TavernGroupEndReason reason;
  final TavernGroupProgress? progress;
  final TavernFailure? failure;
  final String? code;
  final String? detail;
  final String? attemptedCharacterId;
  final TavernMessage? partial;
}

enum TavernGroupError {
  notGroup,
  characterNotFound,
  memberExists,
  memberNotFound,
  invalidMembers,
  invalidTalkativeness,
  invalidLimit,
  invalidOrder,
  hostInUse,
  invalidTitle,
}

class TavernGroupException implements Exception {
  TavernGroupException(this.code, {this.chatId, this.characterId, List<String> relatedChatIds = const [], this.detail})
    : relatedChatIds = List<String>.unmodifiable(relatedChatIds);
  final TavernGroupError code;
  final String? chatId;
  final String? characterId;
  final List<String> relatedChatIds;
  final String? detail;
  @override
  String toString() => 'TavernGroupException(${code.name}${detail == null ? '' : ': $detail'})';
}
