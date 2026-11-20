// The quiet 「来自 ui.json」 tag next to a setting that the host's ui.json decides.
// Tapping it shows where in the file the value comes from and offers 「恢复默认」,
// which only sets that setting aside in the app — the file is left as it is.
//
// The control itself should be greyed out while the tag shows:
// `ref.watch(uiSettingEntryProvider(key)) != null`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../ui/common/app_sheet.dart';
import '../../ui/engine_settings/field_row.dart' show FieldBadge;
import '../../ui/settings/settings_widgets.dart' show InfoRow;
import '../ui_config_ignores.dart';
import '../ui_config_labels.dart';
import '../ui_config_model.dart';
import '../ui_config_state.dart';

/// The tag's words.
String get fromUiJsonLabel => appL10n.shellFromUiJson;

/// 「来自 ui.json」 when the active host's ui.json sets [setting]; nothing
/// otherwise. Put it after the row's title (like `FieldBadge`).
class FromUiJsonBadge extends ConsumerWidget {
  const FromUiJsonBadge(this.setting, {super.key});

  final UiSettingKey setting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final entry = ref.watch(uiSettingEntryProvider(setting));
    if (entry == null) return const SizedBox.shrink();
    void open() => unawaited(showUiOverrideSheet(context, setting));
    return Semantics(
      button: true,
      label: l10n.shellFromUiJson,
      hint: l10n.shellViewSource,
      onTap: open,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('from-ui-json-${setting.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: FieldBadge(l10n.shellFromUiJson)),
      ),
    );
  }
}

/// Where [setting]'s value comes from, with 「恢复默认」.
Future<void> showUiOverrideSheet(BuildContext context, UiSettingKey setting) =>
    showAppSheet<void>(context, builder: (_) => UiOverrideSheet(setting: setting));

class UiOverrideSheet extends ConsumerWidget {
  const UiOverrideSheet({super.key, required this.setting});

  final UiSettingKey setting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final entry = ref.watch(uiSettingEntryProvider(setting));
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.shellFromUiJson),
          if (entry != null)
            SheetGroup(
              children: [
                InfoRow(label: l10n.shellSourcePosition, value: entry.pointer, mono: true),
                InfoRow(label: uiSettingLabel(entry).$1, value: uiSettingLabel(entry).$2),
              ],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 16),
            child: FilledButton(
              key: const ValueKey('ui-json-restore-default'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: entry == null
                  ? null
                  : () async {
                      final navigator = Navigator.of(context);
                      await restoreUiDefault(
                        ref.read(uiOverridesProvider),
                        ref.read(uiIgnoresProvider.notifier),
                        setting,
                      );
                      if (navigator.mounted) navigator.pop();
                    },
              child: Text(l10n.shellRestoreDefaults),
            ),
          ),
        ],
      ),
    );
  }
}
