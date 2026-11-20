// 个性化: what AI should know about you (个人偏好), how it answers (可视化回复)
// and how it works (Agent 预设). The first two live in this phone's engine,
// so a remote host shows only the presets.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../share_code/guest_fs.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../features/agent_presets_page.dart';
import '../shell/page_frame.dart';
import 'reply_prefs_page.dart';
import 'settings_widgets.dart';

/// Whether 个人偏好 can be read and written here: this phone's engine, with
/// its files at hand.
bool canEditReplyPrefs(WidgetRef ref) =>
    ref.watch(activeHostProvider).isLocal && ref.watch(guestFsProvider).value != null;

/// The first line of 个人偏好, or null when there is none.
String? replyPrefsSummary(WidgetRef ref) {
  final line = ref.watch(replyPrefsProvider).value?.trim().split('\n').first.trim();
  return line == null || line.isEmpty ? null : line;
}

class PersonalizationPage extends ConsumerWidget {
  const PersonalizationPage({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /// The engine reads its instructions at launch, so the switch takes effect on
  /// the next start; offer one now rather than restarting behind the user's back.
  Future<void> _onVisualReplies(BuildContext context, WidgetRef ref, bool next) async {
    await ref.read(settingsProvider.notifier).setVisualReplies(next);
    if (!context.mounted || ref.read(localRuntimeProvider).status.phase != RuntimePhase.running) return;
    final container = ProviderScope.containerOf(context, listen: false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.l10n.hubSettingsRestartRequired),
          persist: false,
          action: SnackBarAction(
            label: context.l10n.hubSettingsRestartNow,
            onPressed: () => unawaited(EngineControl.restart(container)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final local = ref.watch(activeHostProvider).isLocal;
    final prefs = canEditReplyPrefs(ref);
    final summary = prefs ? replyPrefsSummary(ref) : null;
    return AppPage.list(
      title: l10n.hubPersonalization,
      children: [
        if (prefs)
          SettingsSection(
            title: l10n.hubPersonalizationAboutYou,
            children: [
              SettingsTile(
                spot: SettingsIndex.entry(SettingsPageId.replyPrefs),
                subtitle: summary ?? l10n.commonNotSet,
                onTap: () => _push(context, const ReplyPrefsPage()),
              ),
            ],
          ),
        if (local)
          SettingsSection(
            title: l10n.hubPersonalizationReplies,
            children: [
              SettingsSwitchTile(
                spot: Spots.visualReplies,
                subtitle: l10n.hubSettingsVisualRepliesHint,
                value: ref.watch(settingsProvider.select((s) => s.visualReplies)),
                onChanged: (v) => unawaited(_onVisualReplies(context, ref, v)),
              ),
            ],
          ),
        SettingsSection(
          title: l10n.hubPersonalizationWorkStyle,
          children: [
            SettingsTile(
              spot: SettingsIndex.entry(SettingsPageId.agentPresets),
              onTap: () => _push(context, const AgentPresetsPage()),
            ),
          ],
        ),
      ],
    );
  }
}
