// Under a reply: what its turn did with tools (STAGE1-APP-INTEGRATION §4, §5)
// — the dice the model rolled, as the engine adopted them, and what it
// proposed to remember, with 记住 / 不用 while that can still be decided.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_tool_turns.dart';
import '../theme/theme.dart';

/// [code] (a not-applied decision's reason, a proposal's ineligibility) as
/// the player reads it; one not known here is shown as it is.
String tavernToolReason(L10n l10n, String? code) => switch (code) {
  'revision_conflict' => l10n.tavernToolReasonRevision,
  'already_resolved' => l10n.tavernToolReasonResolved,
  'context_changed' => l10n.tavernToolReasonContext,
  'source_deleted' => l10n.tavernToolReasonDeleted,
  'source_changed' => l10n.tavernToolReasonChanged,
  'not_on_branch' => l10n.tavernToolReasonBranch,
  'inactive' => l10n.tavernToolReasonInactive,
  null || '' => l10n.tavernToolReasonUnknown,
  final other => other,
};

/// A roll as it reads: committed, its faces and total (the engine's, never
/// rolled again here); not settled, said to be so; not done, said too.
String tavernToolRollText(L10n l10n, TavernToolReceipt roll) {
  final params = roll.capturedParameters;
  final asked = switch (params['dice']) {
    final String dice => dice,
    _ => '?',
  };
  final result = roll.result;
  final label = switch (result?['label'] ?? params['label']) {
    final String l when l.trim().isNotEmpty => '$l：',
    _ => '',
  };
  return switch (roll.committed) {
    true when result != null => '$label${_committed(l10n, result, asked)}',
    null => '$label${l10n.tavernToolRollUnsettled(asked)}',
    _ => '$label${l10n.tavernToolRollNotDone(asked)}',
  };
}

String _committed(L10n l10n, Map<String, Object?> result, String asked) {
  final values = switch (result['values']) {
    final List<Object?> list => list.whereType<num>().map((v) => v.toInt()).toList(),
    _ => const <int>[],
  };
  final modifier = switch (result['modifier']) {
    final num m => m.toInt(),
    _ => 0,
  };
  final total = switch (result['total']) {
    final num t => t.toInt(),
    _ => values.fold(0, (a, b) => a + b) + modifier,
  };
  final dice = switch (result['dice']) {
    final String d => d,
    _ => asked,
  };
  final working = values.length == 1 && modifier == 0 || values.isEmpty
      ? null
      : '${values.join(' + ')}${switch (modifier) {
          0 => '',
          > 0 => ' + $modifier',
          _ => ' − ${-modifier}',
        }}';
  final line = l10n.tavernDiceLine(dice, total, working == null ? '' : l10n.tavernDiceWorking(working));
  return switch ((result['target'], result['pass'])) {
    (final num target, true) => '$line · ${l10n.tavernToolRollPass(target.toInt())}',
    (final num target, false) => '$line · ${l10n.tavernToolRollFail(target.toInt())}',
    _ => line,
  };
}

class TavernToolStrip extends StatelessWidget {
  const TavernToolStrip({super.key, required this.view, required this.onDecide, required this.onRetry});

  final TavernToolTurnView view;

  /// 记住 / 不用 on a proposal waiting for the player.
  final void Function(TavernMemoryProposalSnapshot proposal, TavernMemoryDecision decision) onDecide;

  /// 重试: the decision that did not go through, sent again unchanged.
  final void Function(TavernMemoryIntent intent) onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final quiet = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final roll in view.rolls)
            Text(key: ValueKey('tavern-tool-roll-${roll.executionId}'), tavernToolRollText(l10n, roll), style: quiet),
          for (final proposal in view.turn.proposals)
            _Proposal(key: ValueKey('tavern-tool-memory-${proposal.proposalId}'), proposal: proposal, strip: this),
        ],
      ),
    );
  }
}

class _Proposal extends ConsumerWidget {
  const _Proposal({super.key, required this.proposal, required this.strip});

  final TavernMemoryProposalSnapshot proposal;
  final TavernToolStrip strip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary);
    final open = proposal.workflow == 'pending_confirmation' && proposal.eligible;
    // A decision kept from before is read first: until it is, no buttons,
    // so a tap cannot replace it.
    final kept = open ? ref.watch(tavernMemoryIntentProvider(proposal.proposalId)) : null;
    final waiting = kept?.value;
    final state = switch (proposal.workflow) {
      'staged' => l10n.tavernToolMemoryStaged,
      'pending_confirmation' when !proposal.eligible => l10n.tavernToolMemoryIneligible(
        tavernToolReason(l10n, proposal.ineligibleReason),
      ),
      'pending_confirmation' => null,
      'accepted' when proposal.lastDecisionRef?.origin == 'policy_auto' => l10n.tavernToolMemoryAuto,
      'accepted' => l10n.tavernToolMemoryAccepted,
      'rejected' => l10n.tavernToolMemoryRejected,
      'inactive_terminal' => l10n.tavernToolMemoryInactive,
      final other => other,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusMd,
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tavernToolMemory(proposal.text), style: theme.textTheme.bodySmall),
            if (state != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(state, style: quiet),
              ),
            if (open && waiting != null)
              Row(
                children: [
                  Expanded(child: Text(l10n.tavernToolMemoryWaiting, style: quiet)),
                  TextButton(
                    key: ValueKey('tavern-tool-memory-retry-${proposal.proposalId}'),
                    onPressed: () => strip.onRetry(waiting),
                    child: Text(l10n.commonRetry),
                  ),
                ],
              )
            else if (open && kept?.isLoading != true)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: ValueKey('tavern-tool-memory-reject-${proposal.proposalId}'),
                    onPressed: () => strip.onDecide(proposal, TavernMemoryDecision.reject),
                    child: Text(l10n.tavernToolMemoryReject),
                  ),
                  TextButton(
                    key: ValueKey('tavern-tool-memory-accept-${proposal.proposalId}'),
                    onPressed: () => strip.onDecide(proposal, TavernMemoryDecision.accept),
                    child: Text(l10n.tavernToolMemoryAccept),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
