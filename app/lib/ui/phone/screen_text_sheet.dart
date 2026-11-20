import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../phone/phone_channel.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_widgets.dart';

/// Shows what 「读一下当前屏幕」 got back: the text form the model would see, in
/// a code well, or why reading failed.
Future<void> showScreenTextSheet(BuildContext context, ScreenTestResult result) => showAppSheet<void>(
  context,
  heightFactor: result.ok ? 0.82 : null,
  isScrollControlled: true,
  builder: (_) => ScreenTextSheet(result: result),
);

class ScreenTextSheet extends StatelessWidget {
  const ScreenTextSheet({super.key, required this.result});

  final ScreenTestResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final text = result.text ?? '';
    if (!result.ok) {
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(l10n.phoneScreenReadFailed),
            PhoneNote(
              tone: NoteTone.warn,
              text: result.reason ?? l10n.phoneScreenUnknownReason,
              margin: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 10),
            ),
            Padding(padding: const EdgeInsets.only(bottom: 16), child: _Hint(l10n.phoneScreenReadFailedHint)),
          ],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            l10n.phoneScreenCurrent,
            actions: [
              IconButton(
                tooltip: l10n.commonCopy,
                icon: const Icon(AppIcons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) showBriefNotice(context, l10n.commonCopied);
                },
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: colors.codeWellBg,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: AppShape.radiusMd,
                    side: BorderSide(color: colors.codeWellBorder),
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      text.isEmpty ? l10n.phoneScreenEmpty : text,
                      style: AppType.monoSmall(color: colors.codeWellFg),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
            child: _Hint(l10n.phoneScreenReadNote, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
      child: Text(
        text,
        style: (style ?? theme.textTheme.bodySmall)?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
      ),
    );
  }
}
