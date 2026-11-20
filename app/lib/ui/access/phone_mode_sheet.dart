// First run, right after 手机操控's disclosure: ask at the key steps, or run
// on its own the whole way. Nothing is chosen to begin with; 全程自动 says
// what still stays with the person before it can be confirmed.
//
// ```
//   选择确认方式                          (×)
//   随时可在设置里更改
//   ╭──────────────────────────────────╮
//   │ ✋ 关键步骤先问我               ○ │
//   │    进新 App、发送、删除、付款前先问 │
//   │ ⚡ 全程自动                     ● │
//   │    不再询问，全程免打扰           │
//   ╰──────────────────────────────────╯
//   ╭ ⓘ 这些仍由你来操作 ──────────────╮   (全程自动 only)
//   │ 系统设置和权限页面、密码和验证码、… │
//   │ 如需让 AI 操作系统设置、密码等，…   │
//   ╰──────────────────────────────────╯
//   (            开启全程自动            )
// ```

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/app_sheet.dart';
import '../common/expand_reveal.dart';
import '../common/list_page_row.dart';
import '../phone/phone_widgets.dart';
import '../theme/app_icons.dart';

/// The two first-run ways, as the policies' modes.
const phoneModeChoices = [PhoneConfirmMode.ask, PhoneConfirmMode.always];

/// The chosen mode; null when the sheet was closed without one.
Future<PhoneConfirmMode?> showPhoneModeSheet(BuildContext context) => showAppSheet<PhoneConfirmMode>(
  context,
  isScrollControlled: true,
  builder: (_) => const PhoneModeSheet(),
);

class PhoneModeSheet extends StatefulWidget {
  const PhoneModeSheet({super.key});

  @override
  State<PhoneModeSheet> createState() => _PhoneModeSheetState();
}

class _PhoneModeSheetState extends State<PhoneModeSheet> {
  PhoneConfirmMode? _picked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final picked = _picked;
    final auto = picked == PhoneConfirmMode.always;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.phoneModeTitle),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                    child: Text(
                      l10n.phoneModeMessage,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  SheetGroup(
                    key: const ValueKey('phone-mode-choices'),
                    children: [
                      for (final mode in phoneModeChoices)
                        _ModeRow(mode: mode, selected: mode == picked, onTap: () => setState(() => _picked = mode)),
                    ],
                  ),
                  ExpandReveal(
                    open: auto,
                    child: PhoneNote(
                      key: const ValueKey('phone-mode-auto-note'),
                      icon: AppIcons.lock,
                      title: l10n.phoneModeAutoNoteTitle,
                      text: '${l10n.phoneModeAutoNote}\n${l10n.phoneModeAutoUnlockNote}',
                      margin: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 0),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
            child: FilledButton(
              key: const ValueKey('phone-mode-confirm'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: picked == null ? null : () => Navigator.pop(context, picked),
              child: Text(auto ? l10n.phoneModeConfirmAuto : l10n.commonContinue),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.mode, required this.selected, required this.onTap});

  final PhoneConfirmMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final ask = mode == PhoneConfirmMode.ask;
    return MergeSemantics(
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: ListPageRow(
          key: ValueKey('phone-mode-${mode.name}'),
          icon: ask ? AppIcons.askFirst : AppIcons.noConfirm,
          title: ask ? l10n.phoneModeAsk : l10n.phoneModeAuto,
          subtitle: ask ? l10n.phoneModeAskHint : l10n.phoneModeAutoHint,
          subtitleMaxLines: 2,
          chevron: false,
          onTap: onTap,
          trailing: Icon(
            selected ? AppIcons.radioOn : AppIcons.radioOff,
            key: ValueKey('phone-mode-${mode.name}-mark'),
            size: 22,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
