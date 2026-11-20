// Stage one's tools in a chat (STAGE1-APP-INTEGRATION §3, §5, §9): what each
// reply's logical turn did — the dice the model rolled, what it proposed to
// remember — as the engine has it, never made up from the reply's text.

import 'dart:convert';
import 'dart:math';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tavern_preview.dart';
import 'tavern_provider.dart';

/// One logical turn's tools as last read: the turn and each of its receipts.
class TavernToolTurnView {
  const TavernToolTurnView(this.turn, this.receipts);

  final TavernToolTurnSnapshot turn;

  /// By execution id (a receipt's id is its execution id), as the turn lists
  /// them; one that could not be read is missing.
  final Map<String, TavernToolReceipt> receipts;

  /// The dice the model rolled in this turn, in the order it asked.
  List<TavernToolReceipt> get rolls => [
    for (final id in turn.receiptIds)
      if (receipts[id] case final receipt? when receipt.kind == 'roll') receipt,
  ];

  /// Whether there is anything to show under the reply.
  bool get shows => rolls.isNotEmpty || turn.proposals.isNotEmpty;

  /// The reply this turn wrote: its own candidate, else where what it
  /// proposed to remember was written.
  String? get replyNodeId => turn.candidateSource?.nodeId ?? turn.proposals.map((p) => p.candidateNodeId).firstOrNull;
}

/// Reads [logicalTurnId] and its receipts; null when the engine has no such
/// turn. A receipt that is gone is left out, not made up.
Future<TavernToolTurnView?> tavernReadToolTurn(Tavern tavern, String logicalTurnId) async {
  final turn = await tavern.readToolTurn(logicalTurnId);
  if (turn == null) return null;
  final receipts = <String, TavernToolReceipt>{};
  for (final id in turn.receiptIds) {
    if (await tavern.readToolReceipt(id) case final receipt?) receipts[id] = receipt;
  }
  return TavernToolTurnView(turn, receipts);
}

/// How many of the chat's newest tool turns are shown under their replies.
const tavernToolTurnDiscovery = 50;

/// A chat's recent tool turns that have something to show, by the reply each
/// belongs to ([Tavern.recentToolTurns]: one small query, not the whole
/// prompt of the latest turn). Read afresh when invalidated — after a turn
/// ends, on a tool activity, after a decision. The preview keeps no tool
/// turns, so it is not asked.
final tavernChatToolTurnsProvider = FutureProvider.autoDispose.family<Map<String, List<TavernToolTurnView>>, String>((
  ref,
  chatId,
) async {
  final tavern = ref.watch(tavernProvider);
  if (tavern is TavernPreview) return const {};
  // A continuation is a turn of its own on the reply it continues: a reply
  // can have several. The engine lists them newest first; each reply's
  // list here, oldest first. A turn with no reply (yet, or any more) has
  // nowhere to show.
  final byReply = <String, List<TavernToolTurnView>>{};
  for (final summary in await tavern.recentToolTurns(chatId, limit: tavernToolTurnDiscovery)) {
    final node = summary.replyNodeId;
    if (node == null) continue;
    final view = await tavernReadToolTurn(tavern, summary.logicalTurnId);
    if (view == null || !view.shows) continue;
    (byReply[node] ??= []).insert(0, view);
  }
  return byReply;
}, retry: (_, _) => null);

/// A new identity of the app's own (a decision, a dice action): random, never
/// parsed or derived from the engine's ids (§2).
String tavernNewId([Random? random]) {
  final r = random ?? Random.secure();
  return 'dshgo-${[for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
}

/// A memory decision as the player made it (§5.2): the proposal's version
/// and context as they were then, under an id of its own. Kept before it is
/// sent, so a retry sends the very same one; a new look is a new decision.
class TavernMemoryIntent {
  const TavernMemoryIntent({
    required this.proposalId,
    required this.decisionId,
    required this.expectedVersion,
    required this.decision,
    required this.anchor,
  });

  /// Taken from [proposal] as it is now, under [decisionId].
  factory TavernMemoryIntent.of(
    TavernMemoryProposalSnapshot proposal,
    TavernMemoryDecision decision,
    String decisionId,
  ) => TavernMemoryIntent(
    proposalId: proposal.proposalId,
    decisionId: decisionId,
    expectedVersion: proposal.version,
    decision: decision,
    anchor: proposal.contextAnchor.toJson(),
  );

  static TavernMemoryIntent? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final decision = TavernMemoryDecision.values.asNameMap()[json['decision']];
    if (json
        case {
          'proposalId': final String proposalId,
          'decisionId': final String decisionId,
          'expectedVersion': final int version,
          'anchor': final Map<String, Object?> anchor,
        }
        when decision != null) {
      return TavernMemoryIntent(
        proposalId: proposalId,
        decisionId: decisionId,
        expectedVersion: version,
        decision: decision,
        anchor: anchor,
      );
    }
    return null;
  }

  final String proposalId;
  final String decisionId;
  final int expectedVersion;
  final TavernMemoryDecision decision;

  /// The proposal's context anchor as JSON, as it was.
  final Map<String, Object?> anchor;

  Map<String, Object?> toJson() => {
    'proposalId': proposalId,
    'decisionId': decisionId,
    'expectedVersion': expectedVersion,
    'decision': decision.name,
    'anchor': anchor,
  };

  Future<TavernMemoryDecisionReceipt> submit(Tavern tavern) => tavern.resolveMemoryProposal(
    proposalId,
    decisionId: decisionId,
    expectedVersion: expectedVersion,
    decision: decision,
    expectedContextAnchor: TavernToolContextAnchor.fromJson(anchor),
  );
}

/// Where a memory decision waiting to go through is kept, by proposal.
const tavernMemoryIntentKey = 'tavern.memoryIntent.';

Future<void> tavernKeepMemoryIntent(TavernMemoryIntent intent) async => (await SharedPreferences.getInstance())
    .setString('$tavernMemoryIntentKey${intent.proposalId}', jsonEncode(intent.toJson()));

Future<void> tavernForgetMemoryIntent(String proposalId) async =>
    (await SharedPreferences.getInstance()).remove('$tavernMemoryIntentKey$proposalId');

/// The decision on [proposalId] that has not gone through yet, if any: what
/// 重试 sends again, unchanged.
final tavernMemoryIntentProvider = FutureProvider.autoDispose.family<TavernMemoryIntent?, String>((
  ref,
  proposalId,
) async {
  final raw = (await SharedPreferences.getInstance()).getString('$tavernMemoryIntentKey$proposalId');
  if (raw == null) return null;
  try {
    return TavernMemoryIntent.fromJson(jsonDecode(raw));
  } on FormatException {
    return null;
  }
});

/// A dice roll the player asked the engine for (§4): its id and dice, kept
/// before it is sent and until its result is known, so a page rebuilt or a
/// result not yet settled asks again with the very same one — never a new
/// throw in its place.
class TavernRollIntent {
  const TavernRollIntent({required this.chatId, required this.actionId, required this.dice});

  static TavernRollIntent? fromJson(Object? json) => switch (json) {
    {'chatId': final String chatId, 'actionId': final String actionId, 'dice': final String dice} => TavernRollIntent(
      chatId: chatId,
      actionId: actionId,
      dice: dice,
    ),
    _ => null,
  };

  final String chatId;
  final String actionId;

  /// As the engine takes it: 1d20, 2d6+1, 3d8-2.
  final String dice;

  Map<String, Object?> toJson() => {'chatId': chatId, 'actionId': actionId, 'dice': dice};

  Future<TavernToolReceipt> submit(Tavern tavern) => tavern.rollDice(chatId, actionId: actionId, dice: dice);
}

/// Where the roll waiting to be settled is kept, by chat.
const tavernRollIntentKey = 'tavern.rollIntent.';

Future<void> tavernKeepRollIntent(TavernRollIntent intent) async => (await SharedPreferences.getInstance()).setString(
  '$tavernRollIntentKey${intent.chatId}',
  jsonEncode(intent.toJson()),
);

Future<void> tavernForgetRollIntent(String chatId) async =>
    (await SharedPreferences.getInstance()).remove('$tavernRollIntentKey$chatId');

/// The roll in [chatId] not settled yet, if any.
Future<TavernRollIntent?> tavernRollIntent(String chatId) async {
  final raw = (await SharedPreferences.getInstance()).getString('$tavernRollIntentKey$chatId');
  if (raw == null) return null;
  try {
    return TavernRollIntent.fromJson(jsonDecode(raw));
  } on FormatException {
    return null;
  }
}
