import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../common/search_capsule.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'appearance/appearance_page.dart';
import 'language_tile.dart';
import 'performance_page.dart';
import 'search/settings_search_page.dart';
import 'settings_widgets.dart';
import 'index/settings_pages.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    Widget entry(SettingsPageId id) => SettingsTile(
      spot: SettingsIndex.entry(id),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => settingsPage(id))),
    );
    return AppPage.list(
      title: l10n.commonSettings,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SearchCapsuleButton(
            hint: l10n.searchSettingsHint,
            onTap: () => Navigator.of(context).push(SettingsSearchPage.route()),
          ),
        ),
        SettingsSection(
          title: l10n.hubGroupAi,
          children: [
            entry(SettingsPageId.models),
            entry(SettingsPageId.permission),
            entry(SettingsPageId.agentPresets),
          ],
        ),
        SettingsSection(
          title: l10n.hubSettingsAppearance,
          children: [
            const AppearanceEntryTile(),
            SettingsSegmentTile<double>(
              icon: AppIcons.textSize,
              spot: Spots.chatTextSize,
              segments: [for (final (scale, label) in chatTextScales) PillSegment(scale, label)],
              selected: settings.chatTextScale,
              onChanged: (scale) => unawaited(notifier.setChatTextScale(scale)),
            ),
            SettingsSwitchTile(
              spot: Spots.foldTurns,
              value: settings.foldCompletedTurns,
              onChanged: (value) => unawaited(notifier.setFoldCompletedTurns(value)),
            ),
          ],
        ),
        const SettingsSection(children: [LanguageSettingsTile(), PerformanceSettingsTile()]),
        SettingsSection(children: [entry(SettingsPageId.remote), entry(SettingsPageId.about)]),
      ],
    );
  }
}
