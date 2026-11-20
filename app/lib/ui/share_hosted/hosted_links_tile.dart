// 「我的分享链接」 on 隐私与分享, with how many there are.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../share_hosted/hosted_links_state.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'hosted_links_page.dart';

class HostedLinksSettingsTile extends ConsumerWidget {
  const HostedLinksSettingsTile({super.key, this.tint = 0, this.icon = true});

  /// The hub group's hue.
  final int tint;

  /// False on a secondary page: a plain row.
  final bool icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(hostedLinksProvider.select((s) => s.visible.length));
    return SettingsTile(
      icon: icon ? AppIcons.link : null,
      tint: tint,
      spot: SettingsIndex.entry(SettingsPageId.sharedLinks),
      value: count == 0 ? null : Text('$count', style: AppType.tabular(Theme.of(context).textTheme.bodyMedium!)),
      onTap: () => Navigator.of(context).push(HostedLinksPage.route()),
    );
  }
}
