// The pieces of the 社区 hub: a picked plugin's row,
// prompt tiles, group rows and the group sheet with its QR code.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/community_state.dart';
import '../../state/plugins_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../plugins/plugin_detail_sheet.dart' show showMarketPluginSheet;
import '../plugins/plugin_widgets.dart';
import '../settings/settings_widgets.dart' show SettingsTile;
import '../share/qr_code.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// One hue per hub group (`DshColors.identity`).
abstract final class CommunityHues {
  static const prompts = 0;
  static const groups = 5;
  static const forum = 2;
}

/// Opens [url] outside the app; false when nothing could.
Future<bool> openCommunityLink(BuildContext context, String url) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  var ok = false;
  try {
    ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok) messenger?.showSnackBar(SnackBar(content: Text(l10n.botsLinkOpenFailed(uri?.host ?? l10n.botsLink))));
  return ok;
}

/// `10月24日` this year, `2025年10月` before.
String communityDate(DateTime t, {DateTime? now}) {
  final local = t.toLocal();
  return local.year == (now ?? DateTime.now()).year
      ? appL10n.monthDay(local)
      : appL10n.botsYearMonth(local.year, local.month.toString());
}

/// The prompt tiles' icon set (names used in `community.json`).
IconData communityPromptIcon(String? name) => switch (name) {
  'code' => AppIcons.code,
  'doc' => AppIcons.document,
  'bug' => AppIcons.bug,
  'chart' => AppIcons.chart,
  'school' => AppIcons.school,
  'travel' => AppIcons.travel,
  'search' => AppIcons.webSearch,
  'image' => AppIcons.image,
  'write' => AppIcons.write,
  'translate' => AppIcons.translate,
  'terminal' => AppIcons.terminal,
  'mail' => AppIcons.mail,
  'calendar' => AppIcons.calendar,
  _ => AppIcons.featured,
};

IconData communityGroupIcon(String kind) => switch (kind) {
  'qq' => AppIcons.qq,
  'wechat' => AppIcons.wechat,
  'telegram' => AppIcons.telegram,
  'discord' => AppIcons.discord,
  'forum' => AppIcons.forum,
  'github' => AppIcons.code,
  _ => AppIcons.link,
};

/// A recommended plugin, market-row style: icon, name, the curator's line,
/// and the 获取 capsule. Every state opens the market's detail sheet, where
/// installing happens (with its trust note), like the market itself.
class CommunityPluginRow extends ConsumerWidget {
  const CommunityPluginRow({super.key, required this.pick, required this.entry});

  final CommunityPlugin pick;

  /// The plugin in the market index; null while the index loads.
  final MarketEntry? entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = this.entry;
    final plugin = entry?.plugin;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final job = plugin == null ? null : ref.watch(pluginInstallsProvider.select((jobs) => jobs[plugin.name]));
    final title = plugin?.displayTitle() ?? pick.name;
    final subtitle = pick.note ?? plugin?.displayDescription() ?? plugin?.author;
    void open() => unawaited(showMarketPluginSheet(context, entry!));
    return ListPageRow(
      leading: PluginAvatar(name: pick.name, title: title, icon: plugin?.icon),
      leadingWidth: 40,
      title: title,
      titleStyle: pluginRowTitle(context),
      subtitle: subtitle,
      trailing: PluginInstallButton(
        status: plugin == null ? MarketInstallStatus.notInstalled : marketInstallStatus(plugin, bundles),
        job: job,
        onPressed: entry == null ? null : open,
      ),
      onTap: entry == null ? null : open,
    );
  }
}

/// A group or forum link as a hub row: tinted icon, name, one line. Groups
/// with a QR code or a number open [showCommunityGroupSheet] (a QR glyph at
/// the end says so); plain links open in the browser (a chevron).
class CommunityGroupRow extends StatelessWidget {
  const CommunityGroupRow({super.key, required this.group});

  final CommunityGroup group;

  @override
  Widget build(BuildContext context) {
    final sheet = group.qrData != null || group.copy != null;
    return SettingsTile(
      icon: communityGroupIcon(group.kind),
      tint: CommunityHues.groups,
      title: group.title,
      subtitle: group.subtitle,
      trailing: sheet ? Icon(AppIcons.qrCode, size: 20, color: DshColors.of(context).textTertiary) : null,
      onTap: () => sheet
          ? unawaited(showCommunityGroupSheet(context, group))
          : unawaited(openCommunityLink(context, group.url!)),
    );
  }
}

/// A group up close: the QR code (to scan from another phone or to save),
/// then 「复制」 and 「打开」.
Future<void> showCommunityGroupSheet(BuildContext context, CommunityGroup group) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => CommunityGroupSheet(group: group));

class CommunityGroupSheet extends StatefulWidget {
  const CommunityGroupSheet({super.key, required this.group});

  final CommunityGroup group;

  static const qrSize = 208.0;

  @override
  State<CommunityGroupSheet> createState() => _CommunityGroupSheetState();
}

class _CommunityGroupSheetState extends State<CommunityGroupSheet> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    HapticFeedback.lightImpact();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final group = widget.group;
    final qr = group.qrData;
    final copy = group.copy;
    final url = group.url;
    final copyLabel = group.kind == 'qq' ? l10n.botsCopyGroupNumber : l10n.commonCopy;
    final buttons = <Widget>[
      if (copy != null)
        OutlinedButton.icon(
          key: const ValueKey('group-copy'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => _copy(copy),
          icon: Icon(_copied ? AppIcons.done : AppIcons.copy, size: 18),
          label: Text(_copied ? l10n.commonCopied : copyLabel),
        ),
      if (url != null)
        FilledButton.icon(
          key: const ValueKey('group-open'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => unawaited(openCommunityLink(context, url)),
          icon: const Icon(AppIcons.openExternal, size: 18),
          label: Text(l10n.commonOpen),
        ),
    ];
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(group.title),
          if (qr != null) ...[
            const SizedBox(height: 8),
            Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: Colors.white,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: AppShape.radiusLg,
                    side: theme.brightness == Brightness.dark
                        ? BorderSide.none
                        : BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: QrCodeView(
                    data: qr,
                    size: CommunityGroupSheet.qrSize,
                    quietZone: 1,
                    logo: true,
                    semanticLabel: l10n.botsQrCodeLabel(group.title),
                  ),
                ),
              ),
            ),
          ],
          if (group.subtitle case final subtitle?) ...[
            const SizedBox(height: 16),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: colors.textTertiary)),
            ),
          ],
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
            child: Row(
              children: [
                for (final (i, button) in buttons.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: button),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
