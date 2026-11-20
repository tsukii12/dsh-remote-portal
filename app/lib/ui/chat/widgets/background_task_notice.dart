import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../common/bleed.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../secret_mask.dart';
import 'stream_row.dart';

/// A Host-identified tool-jobs inbox message, separate from human prompts.
/// Body text is display-only: no Markdown, links, reply chips or task routing.
class BackgroundTaskNotice extends StatefulWidget {
  const BackgroundTaskNotice({super.key, required this.prompt});

  final PendingPrompt prompt;

  @override
  State<BackgroundTaskNotice> createState() => _BackgroundTaskNoticeState();
}

class _BackgroundTaskNoticeState extends State<BackgroundTaskNotice> {
  bool _expanded = false;
  int _detailsVersion = 0;
  String? _maskedText;

  @override
  void didUpdateWidget(BackgroundTaskNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.prompt;
    final after = widget.prompt;
    if (before.requestId != after.requestId ||
        before.inboxId != after.inboxId ||
        before.sourceKind != after.sourceKind ||
        before.sourceForm != after.sourceForm ||
        before.text != after.text) {
      _expanded = false;
      _maskedText = null;
      // Reset the reveal too: a replacement must not show its new body
      // during the previous message's collapse animation.
      _detailsVersion++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = widget.prompt.sourceForm == 'notice' ? l10n.chatBackgroundTaskNotice : l10n.chatBackgroundTaskMessage;
    final hasDetails = widget.prompt.text.isNotEmpty;
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Bleed(
          horizontal: StreamRow.bleed,
          child: MergeSemantics(
            child: Semantics(
              expanded: hasDetails ? _expanded : null,
              hint: hasDetails ? (_expanded ? l10n.commonCollapse : l10n.commonDetails) : null,
              child: TextButton(
                onPressed: hasDetails ? () => setState(() => _expanded = !_expanded) : null,
                style: TextButton.styleFrom(
                  foregroundColor: colors.onSurfaceVariant,
                  disabledForegroundColor: colors.onSurfaceVariant,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.all(8),
                  textStyle: StreamRow.label(context),
                  shape: Squircle.border(AppShape.sm),
                ),
                child: Row(
                  children: [
                    const StreamLead(child: Icon(AppIcons.jobs, size: 16)),
                    const SizedBox(width: StreamRow.gap),
                    Expanded(child: Text(title)),
                    if (hasDetails) ...[const SizedBox(width: StreamRow.gap), StreamChevron(open: _expanded)],
                  ],
                ),
              ),
            ),
          ),
        ),
        ExpandReveal(
          key: ValueKey(_detailsVersion),
          open: _expanded,
          child: Builder(
            // Do not scan or lay out the technical body until it is opened.
            builder: (context) => StreamThread(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(
                  _maskedText ??= maskSecrets(widget.prompt.text, mark: '•'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
