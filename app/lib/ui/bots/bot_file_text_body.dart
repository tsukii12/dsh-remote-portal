import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../chat/render/markdown_body.dart';
import '../theme/theme.dart';
import 'bot_text_count.dart';

/// The Host may return only a prefix; never infer completeness from its length.
class BotFileTextBody extends StatelessWidget {
  const BotFileTextBody({super.key, required this.value});
  final DsBotFileText value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (value.whole != true)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            value.whole == false
                ? context.l10n.botsTextPartial(formatBotTextCount(value.text.length, context.l10n.localeName))
                : context.l10n.botsTextCompletenessUnknown,
            key: const ValueKey('bot-file-text-completeness'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
      MarkdownBody(text: value.text),
    ],
  );
}
