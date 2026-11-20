// 「分享配置」 — pick what of the active engine's setup to include (a checklist with
// sizes), then the link / QR code / file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/namespace_labels.dart';
import '../../share_code/profile_export.dart';
import '../../share_code/share_code_state.dart';
import '../../share_code/share_codec.dart';
import '../../share_code/share_link.dart';
import '../../share_code/share_models.dart';
import '../../share_code/share_net.dart';
import '../common/app_sheet.dart';
import '../common/scroll_edge_fade.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'share_code_panel.dart';
import 'share_code_widgets.dart';

/// 「分享配置」 (settings): the active engine's setup as a share code.
Future<void> showShareProfileSheet(BuildContext context) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.drag,
  heightFactor: 0.88,
  builder: (_) => SheetNavigator(root: (_) => const ProfileShareSheet()),
);

/// The second step on its own, for a share built elsewhere.
Future<void> showProfileSharePreview(BuildContext context, ProfileShare share) => showAppSheet<void>(
  context,
  dismissal: SheetDismissal.drag,
  heightFactor: 0.88,
  builder: (_) => SheetNavigator(root: (_) => ProfileSharePreview(share: share)),
);

/// `3 个插件 · 5 项设置 · 2 个技能 · AGENTS.md`.
String profileSummary(ProfileShare p) => [
  if (p.plugins.isNotEmpty) appL10n.pluginsPluginCount(p.plugins.length),
  if (p.settings.isNotEmpty) appL10n.pluginsSettingsCount(p.settings.length),
  if (p.presets.isNotEmpty) appL10n.pluginsPresetCount(p.presets.length),
  if (p.skills.isNotEmpty) appL10n.pluginsSkillCount(p.skills.length),
  if (p.agentsMd != null) 'AGENTS.md',
].join(' · ');

Map<ExportSection, String> get _sectionTitles => {
  ExportSection.settings: appL10n.commonSettings,
  ExportSection.plugins: appL10n.pluginsTitle,
  ExportSection.skills: appL10n.pluginsSkills,
  ExportSection.agentsMd: appL10n.pluginsPersonalPreferences,
};

class ProfileShareSheet extends ConsumerStatefulWidget {
  const ProfileShareSheet({super.key});

  @override
  ConsumerState<ProfileShareSheet> createState() => _ProfileShareSheetState();
}

class _ProfileShareSheetState extends ConsumerState<ProfileShareSheet> {
  Set<String>? _selected;
  bool _building = false;

  Future<void> _next(ProfileExportSource source, Set<String> selected) async {
    if (_building) return;
    setState(() => _building = true);
    var share = source.build(selected);
    try {
      share = await withProfileNpmFacts(ref.read(shareNetProvider), share).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Shared without integrity.
    }
    if (!mounted) return;
    setState(() => _building = false);
    SheetNavigator.of(context).push((_) => ProfileSharePreview(share: share));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final source = ref.watch(profileExportProvider);
    final Widget body;
    Widget? footer;
    switch (source) {
      case AsyncData(value: final s?) when s.items.isNotEmpty:
        final selected = _selected ??= s.defaultSelection;
        final share = s.build(selected, now: DateTime.utc(2026));
        final bytes = share.isEmpty ? 0 : ShareLink.inline(ShareKind.profile, encodeShareCode(share)).webLink.length;
        body = ScrollEdgeFade(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final section in ExportSection.values)
                if (s.section(section).isNotEmpty)
                  SheetGroup(
                    title: _sectionTitles[section],
                    children: [
                      for (final item in s.section(section))
                        ListPageRow(
                          key: ValueKey('share-item-${item.id}'),
                          title: item.title,
                          titleStyle: item.monoTitle
                              ? AppType.mono(size: 14, color: theme.colorScheme.onSurface)
                              : null,
                          subtitle: item.subtitle,
                          meta: item.available ? formatShareBytes(item.bytes) : null,
                          trailing: ShareCheck(value: selected.contains(item.id), enabled: item.available),
                          onTap: item.available
                              ? () => setState(() {
                                  final next = {...selected};
                                  if (!next.remove(item.id)) next.add(item.id);
                                  _selected = next;
                                })
                              : null,
                        ),
                    ],
                  ),
            ],
          ),
        );
        footer = Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  share.isEmpty
                      ? l10n.pluginsNothingSelected
                      : bytes <= maxInlineLinkChars
                      ? l10n.pluginsSelectedQrCount(selected.length)
                      : l10n.pluginsSelectedFileCount(selected.length),
                  key: const ValueKey('share-profile-summary'),
                  style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const ValueKey('share-profile-next'),
                style: FilledButton.styleFrom(minimumSize: const Size(112, 44)),
                onPressed: share.isEmpty || _building ? null : () => _next(s, selected),
                child: _building
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          strokeCap: StrokeCap.round,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : Text(l10n.pluginsNext),
              ),
            ],
          ),
        );
      case AsyncData():
        body = _Quiet(
          icon: AppIcons.shareBundle,
          text: source.value == null ? l10n.commonEngineUnreachable : l10n.pluginsNothingToShare,
        );
      case AsyncError():
        body = _Quiet(icon: AppIcons.offline, text: l10n.pluginsProfileReadFailed);
      default:
        body = Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: colors.textTertiary),
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(l10n.pluginsShareProfile),
        Expanded(child: body),
        if (footer != null) SafeArea(top: false, child: footer),
      ],
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: colors.textTertiary),
          const SizedBox(height: 12),
          Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

/// Step two: what is in it, then the ways out.
class ProfileSharePreview extends StatelessWidget {
  const ProfileSharePreview({super.key, required this.share});

  final ProfileShare share;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = l10n.pluginsProfileTitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(l10n.pluginsShareProfile),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 12),
          child: ShareHero(leading: const ProfileTile(), title: share.name ?? title, subtitle: profileSummary(share)),
        ),
        Expanded(
          child: ScrollEdgeFade(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (share.plugins.isNotEmpty)
                  SheetGroup(
                    title: l10n.pluginsTitle,
                    children: [
                      for (final p in share.plugins)
                        ListPageRow(
                          title: p.displayTitle,
                          value: p.version ?? (p.source == PluginSourceKind.official ? l10n.pluginsOfficial : p.gitRef),
                        ),
                    ],
                  ),
                if (share.settings.isNotEmpty)
                  SheetGroup(
                    title: l10n.commonSettings,
                    children: [
                      for (final MapEntry(key: ns, value: values) in share.settings.entries)
                        ListPageRow(
                          title: namespaceLabel(ns),
                          titleStyle: hasNamespaceLabel(ns)
                              ? null
                              : AppType.mono(size: 14, color: Theme.of(context).colorScheme.onSurface),
                          value: l10n.commonItemCount(values.length),
                        ),
                    ],
                  ),
                if (share.skills.isNotEmpty)
                  SheetGroup(
                    title: l10n.pluginsSkills,
                    children: [
                      for (final s in share.skills)
                        ListPageRow(title: s.name, value: l10n.pluginsFileCount(s.files.length)),
                    ],
                  ),
                if (share.agentsMd case final text?)
                  SheetGroup(
                    title: l10n.pluginsPersonalPreferences,
                    children: [ListPageRow(title: 'AGENTS.md', value: l10n.pluginsLineCount(text.split('\n').length))],
                  ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 20),
            child: ShareCodePanel(payload: share, title: share.name ?? title),
          ),
        ),
      ],
    );
  }
}
