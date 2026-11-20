import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(BuildContext context, String address) async {
    try {
      if (await launchUrl(Uri.parse(address), mode: LaunchMode.externalApplication)) return;
    } on Object {
      // Report the same failure whether the platform refuses or throws.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.stateBrowserOpenFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.hubAbout,
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const BrandMark(size: 88, tile: true),
              const SizedBox(height: 12),
              Text(AppInfo.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(l10n.portalRemoteOnly, textAlign: TextAlign.center),
            ],
          ),
        ),
        SettingsSection(
          children: [
            SettingsTile(spot: Spots.version, value: Text(AppInfo.displayVersion)),
            SettingsTile(
              title: l10n.portalProjectRepository,
              subtitle: AppInfo.repositoryUrl,
              onTap: () => _open(context, AppInfo.repositoryUrl),
            ),
            SettingsTile(
              spot: Spots.licenses,
              subtitle: 'AGPL-3.0',
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: AppInfo.displayVersion,
                applicationIcon: const Padding(padding: EdgeInsets.all(12), child: BrandMark(size: 56, tile: true)),
                applicationLegalese: l10n.portalLicenseSplit,
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.portalUpstreamCredit,
          children: [
            SettingsTile(
              title: 'dsh-Go v1.2.0 · ccch1mneyyy',
              subtitle: 'AGPL-3.0',
              onTap: () => _open(context, 'https://github.com/ccch1mneyyy/dsh-Go/releases/tag/v1.2.0'),
            ),
            SettingsTile(title: l10n.portalArtworkCredit),
          ],
        ),
      ],
    );
  }
}
