// The rows that say where replies come from — 渠道, 模型, 思考 — shared by
// 酒馆设置 and the stage panel's 本局. DeepSeek's own channel offers its two
// models as pills and 「自定义」 for any other name; an added channel's model
// is edited on that channel.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_settings.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../workspace/text_prompt.dart';
import 'tavern_channels_page.dart';

/// [keyPrefix] tells the two places apart (`tavern` / `tavern-session`);
/// [tinted] false draws the icons as on secondary pages; [open] pushes a
/// page (the stage panel closes its drawer first).
List<Widget> tavernModelRows(
  BuildContext context,
  WidgetRef ref, {
  required String keyPrefix,
  bool tinted = true,
  bool thinkingSubtitle = true,
  void Function(Route<void> route)? open,
}) {
  final l10n = context.l10n;
  final settings = ref.watch(tavernSettingsProvider);
  final controller = ref.read(tavernSettingsProvider.notifier);
  final channel = settings.activeChannel;
  final push = open ?? (route) => unawaited(Navigator.of(context).push(route));
  final typed = !tavernModels.contains(settings.model);
  Future<void> typeModel() async {
    final name = await showTextPrompt(
      context,
      title: l10n.tavernModelName,
      initial: typed ? settings.model : '',
      hint: 'deepseek-…',
      mono: true,
      validate: (text) => text.isEmpty ? l10n.tavernChannelModelMissing : null,
    );
    if (name != null) await controller.setModel(name);
  }

  return [
    SettingsTile(
      key: ValueKey('$keyPrefix-channel'),
      icon: AppIcons.providers,
      tinted: tinted,
      title: l10n.tavernChannel,
      value: Text(channel?.name ?? l10n.tavernChannelDeepSeek),
      onTap: () => push(TavernChannelsPage.route()),
    ),
    if (channel == null)
      SettingsSegmentTile<String?>(
        key: ValueKey('$keyPrefix-model'),
        icon: AppIcons.model,
        tinted: tinted,
        title: l10n.tavernSettingsModel,
        segments: [
          PillSegment(tavernModels[0], l10n.tavernModelFlash),
          PillSegment(tavernModels[1], l10n.tavernModelPro),
          PillSegment(null, typed ? settings.model : l10n.tavernNumberCustom),
        ],
        selected: typed ? null : settings.model,
        onChanged: (model) => unawaited(model == null ? typeModel() : controller.setModel(model)),
        onReselect: (model) {
          if (model == null) unawaited(typeModel());
        },
      )
    else
      SettingsTile(
        key: ValueKey('$keyPrefix-model'),
        icon: AppIcons.model,
        tinted: tinted,
        title: l10n.tavernSettingsModel,
        value: Text(channel.model),
        onTap: () => push(TavernChannelEditPage.route(channel)),
      ),
    if (settings.deepseekApi)
      SettingsSwitchTile(
        key: ValueKey('$keyPrefix-thinking'),
        icon: AppIcons.generating,
        tinted: tinted,
        title: l10n.tavernThinking,
        subtitle: thinkingSubtitle ? l10n.tavernThinkingSubtitle : null,
        value: settings.thinking,
        onChanged: (on) => unawaited(controller.setThinking(on)),
      ),
  ];
}
