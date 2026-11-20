// The 「问 AI」 entries: a glass key for page bars ([AskAiButton]), the quiet
// link under a risk notice ([AskAiLink]), and [askAi], which both call. The
// question goes into a new conversation's composer and waits for the person
// to send it (lib/state/ask_ai.dart; docs/design/risk-notices-and-ask-ai.md).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/ask_ai.dart';
import '../../state/compose_inbox.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../shell/page_frame.dart' show GlassIconButton;
import '../theme/app_icons.dart';
import 'discard_guard.dart';

export '../../state/ask_ai.dart' show AskAiTopic;

/// Back to the chat — pages and sheets above it closed, unsaved edits only
/// with the person's say-so — with [topic]'s question in a new conversation's
/// composer, focused and not sent.
Future<void> askAi(BuildContext context, AskAiTopic topic) =>
    askAiQuestion(context, topic.question, guidePage: topic.guidePage);

/// [askAi] with a question of the person's own (settings search with no
/// result): [guidePage] rides along where the host takes files.
Future<void> askAiQuestion(BuildContext context, String question, {String guidePage = freeQuestionGuidePage}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (!await DiscardGuard.confirmLeave(context) || !context.mounted) return;
  unawaited(HapticFeedback.selectionClick());
  final host = container.read(activeHostProvider);
  final route = guideRouteFor(
    local: host.isLocal,
    filesAllowed: canStageFiles(container.read(activeConnectionProvider).value, host),
  );
  final request = await askAiQuestionRequest(
    question,
    guidePage,
    route: route,
    read: container.read(guidePageReaderProvider),
  );
  if (!context.mounted) return;
  // The chat first, then the fill: the composer takes focus on the route
  // that is on top by then.
  Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  container.read(composeInboxProvider.notifier).push(request);
}

/// ✦ in a page's top bar ([AppPage.actions]): the same 44 glass circle as
/// the back key it mirrors. Nothing in 网页模式.
class AskAiButton extends ConsumerWidget {
  const AskAiButton(this.topic, {super.key});

  final AskAiTopic topic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(askAiAvailableProvider)) return const SizedBox.shrink();
    return GlassIconButton(
      key: ValueKey('ask-ai-${topic.name}'),
      icon: AppIcons.askAi,
      tooltip: context.l10n.askAiTooltip,
      onPressed: () => unawaited(askAi(context, topic)),
    );
  }
}

/// 「✦ 不确定？问 AI」: a quiet text key, centred under a sheet's main
/// button. Equal room on both sides of its content: the sparkle's own air
/// ([leadingAir]) comes off the leading padding.
class AskAiLink extends StatelessWidget {
  const AskAiLink({super.key, required this.onPressed, this.label});

  final VoidCallback onPressed;

  /// Defaults to 「不确定？问 AI」.
  final String? label;

  /// Side padding inside the key.
  static const inset = 12.0;

  /// Room the sparkle leaves inside its box at [iconSize].
  static const leadingAir = 1.0;

  /// At 1× text; the sparkle grows with the words beside it.
  static const iconSize = 16.0;
  static const gap = 6.0;

  /// The sparkle's size under [scaler].
  static double iconSizeFor(TextScaler scaler) => scaler.scale(iconSize);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = iconSizeFor(MediaQuery.textScalerOf(context));
    final air = leadingAir * size / iconSize;
    return TextButton(
      key: const ValueKey('ask-ai-link'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: EdgeInsetsDirectional.fromSTEB(inset - air, 6, inset, 6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.colorScheme.primary,
        textStyle: theme.textTheme.labelLarge,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.askAi, size: size),
          const SizedBox(width: gap),
          Flexible(child: Text(label ?? context.l10n.riskAskAi, textAlign: TextAlign.center)),
        ],
      ),
    );
  }
}
