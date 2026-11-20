import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../features/agent_presets_page.dart';
import '../../features/permission_page.dart';
import '../../providers/new_chat_defaults_card.dart';
import '../../remote/remote_screen.dart';
import '../../shell/page_frame.dart';
import '../about_page.dart';
import '../appearance/appearance_page.dart';
import '../settings_screen.dart';
import 'spot_anchor.dart';
import 'spots.dart';

export 'spots.dart';

const remoteSettingsPages = {
  SettingsPageId.hub,
  SettingsPageId.models,
  SettingsPageId.permission,
  SettingsPageId.agentPresets,
  SettingsPageId.appearance,
  SettingsPageId.remote,
  SettingsPageId.about,
};

Widget settingsPage(SettingsPageId id, {String? sessionId}) => switch (id) {
  SettingsPageId.hub => const SettingsScreen(),
  SettingsPageId.models => const RemoteModelSettingsPage(),
  SettingsPageId.permission => PermissionPage(sessionId: sessionId),
  SettingsPageId.agentPresets => const AgentPresetsPage(),
  SettingsPageId.appearance => const AppearancePage(),
  SettingsPageId.remote => const RemoteScreen(),
  SettingsPageId.about => const AboutPage(),
};

class RemoteModelSettingsPage extends ConsumerWidget {
  const RemoteModelSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AppPage.list(title: context.l10n.hubSettingsProviders, children: const [NewChatDefaultsCard()]);
}

Widget? settingsPageForLink(String id, {String? sessionId}) {
  final page = SettingsIndex.pageForLink(id);
  if (page != null && remoteSettingsPages.contains(page.id)) return settingsPage(page.id, sessionId: sessionId);
  final spot = SettingsIndex.spotForLink(id);
  if (spot != null && remoteSettingsPages.contains(spot.page)) return spotPage(spot, sessionId: sessionId);
  return null;
}

Widget spotPage(SettingSpot spot, {String? sessionId}) => spot.isEntry
    ? settingsPage(spot.opens!, sessionId: sessionId)
    : SpotFocus(
        target: spot.id,
        child: settingsPage(spot.page, sessionId: sessionId),
      );

Future<void> openSpot(BuildContext context, SettingSpot spot, {String? sessionId}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => spotPage(spot, sessionId: sessionId)));
