// Native mirror of the official Agent 预设 settings section
// (`dsh-client-ui-agent-preset`): the presets, which one new conversations
// use, each preset's YAML, and — natively — 新建 / 复制 / 编辑 (handed to
// creator mode with the exact bundle, preset_editor/) and 删除 (removes the
// bundle that declares a custom preset).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/features_state.dart';
import '../../state/preset_editor_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../plugins/plugin_widgets.dart';
import '../common/list_page_row.dart';
import '../common/smooth_size.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_kit.dart';
import 'feature_widgets.dart';
import 'preset_editor/preset_editor_page.dart';
import '../common/brief_notice.dart';

class AgentPresetsPage extends ConsumerWidget {
  const AgentPresetsPage({super.key});

  Future<void> _setDefault(BuildContext context, WidgetRef ref, AgentPresetInfo preset) async {
    final l10n = context.l10n;
    final client = ref.read(activeConnectionProvider).value?.client;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (client == null) return;
    try {
      await client.setDefaultAgentPreset(preset.id);
      messenger?.showBriefNotice(l10n.featuresPresetDefaultSet(agentPresetName(preset)));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(featureErrorText(l10n.featuresPresetDefaultFailed, e))));
    } finally {
      ref.invalidate(agentPresetsProvider);
    }
  }

  Future<void> _edit(BuildContext context, PresetEditMode mode, {AgentPresetInfo? source, PluginBundle? bundle}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PresetEditorPage(mode: mode, source: source, bundle: bundle),
        ),
      );

  Future<void> _delete(BuildContext context, WidgetRef ref, AgentPresetInfo preset, PluginBundle bundle) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.featuresPresetDeleteTitle(agentPresetName(preset))),
        content: Text(l10n.featuresPresetDeleteHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final removed = await deletePresetBundle(ref, bundle);
      if (removed) {
        messenger?.showBriefNotice(l10n.featuresDeleted);
      } else {
        messenger?.showSnackBar(SnackBar(content: Text(l10n.featuresDeleteFailed)));
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.featuresDeleteFailed)));
    }
  }

  Future<void> _show(BuildContext context, WidgetRef ref, AgentPresetInfo preset) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    final creator = creatorAvailable(ref.read(agentPresetsProvider).value);
    final custom = !builtInAgentPresets.contains(preset.id);
    final action = await showAppSheet<(String, PluginBundle?)>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(agentPresetName(preset)),
            // A short window or large text: the actions scroll under the
            // title instead of overflowing the sheet.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preset.broken ?? agentPresetDescription(preset) case final d?)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            d,
                            style: Theme.of(sheet).textTheme.bodyMedium
                                ?.copyWith(color: Theme.of(sheet).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    SheetGroup(
                      children: [
                        ListPageRow(
                          icon: preset.isDefault ? AppIcons.isDefault : AppIcons.setDefault,
                          title: preset.isDefault
                              ? context.l10n.featuresPresetAlreadyDefault
                              : context.l10n.featuresPresetSetDefault,
                          chevron: false,
                          onTap: preset.isDefault || preset.broken != null
                              ? null
                              : () => Navigator.pop(sheet, ('default', null)),
                        ),
                        ListPageRow(
                          icon: AppIcons.viewConfig,
                          title: context.l10n.featuresPresetViewConfig,
                          onTap: () => Navigator.pop(sheet, ('view', null)),
                        ),
                        if (creator)
                          ListPageRow(
                            icon: AppIcons.copy,
                            title: context.l10n.featuresPresetDuplicate,
                            onTap: () => Navigator.pop(sheet, ('duplicate', null)),
                          ),
                      ],
                    ),
                    if (custom)
                      Consumer(
                        builder: (context, ref, _) {
                          final bundle = ref.watch(presetBundleProvider(preset.id)).value;
                          final removable = bundle != null && client != null && canRemoveBundles(client);
                          return SmoothSize(
                            duration: AppMotion.of(context, AppMotion.standard),
                            curve: AppMotion.std,
                            alignment: Alignment.topCenter,
                            child: bundle == null
                                ? const SizedBox(width: double.infinity)
                                : SheetGroup(
                                    children: [
                                      if (creator)
                                        ListPageRow(
                                          icon: AppIcons.edit,
                                          title: context.l10n.commonEdit,
                                          onTap: () => Navigator.pop(sheet, ('edit', bundle)),
                                        ),
                                      if (removable)
                                        ListPageRow(
                                          icon: AppIcons.delete,
                                          danger: !preset.isDefault,
                                          title: context.l10n.commonDelete,
                                          subtitle: preset.isDefault
                                              ? context.l10n.featuresPresetDefaultDeleteHint
                                              : null,
                                          chevron: false,
                                          onTap: preset.isDefault
                                              ? null
                                              : () => Navigator.pop(sheet, ('delete', bundle)),
                                        ),
                                    ],
                                  ),
                          );
                        },
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case ('default', _):
        await _setDefault(context, ref, preset);
      case ('view', _):
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _PresetDocumentPage(preset: preset)));
      case ('duplicate', _):
        await _edit(context, PresetEditMode.duplicate, source: preset);
      case ('edit', final bundle?):
        await _edit(context, PresetEditMode.edit, source: preset, bundle: bundle);
      case ('delete', final bundle?):
        await _delete(context, ref, preset, bundle);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final presets = ref.watch(agentPresetsProvider);
    final list = presets.value;
    return AppPage.list(
      title: l10n.featuresAgentPresets,
      subtitle: Text(l10n.featuresAgentPresetsSubtitle),
      actions: [
        GlassIconButton(
          icon: AppIcons.add,
          tooltip: l10n.featuresNew,
          onPressed: connected && creatorAvailable(list)
              ? () => unawaited(_edit(context, PresetEditMode.create))
              : null,
        ),
      ],
      children: [
        if (!connected)
          const FeatureOffline()
        else if (list == null && presets.hasError)
          FeatureMessage.error(
            title: l10n.featuresPresetsReadFailed,
            error: presets.error!,
            onRetry: () => ref.invalidate(agentPresetsProvider),
          )
        else if (list == null)
          const FeatureLoading()
        else ...[
          ListPageCard(
            children: [
              for (final (i, preset) in list.indexed)
                FadeSlideIn(
                  index: i,
                  child: ListPageRow(
                    icon: switch (preset.id) {
                      'standard' => AppIcons.presetStandard,
                      'ptc' => AppIcons.presetPtc,
                      'minimal' => AppIcons.presetMinimal,
                      'cordis' => AppIcons.presetCordis,
                      _ => AppIcons.configure,
                    },
                    title: agentPresetName(preset),
                    badge: preset.broken != null
                        ? PluginBadge(l10n.featuresLoadFailed, tone: PluginBadgeTone.danger)
                        : preset.isDefault
                        ? PluginBadge(l10n.featuresNewChatDefault, tone: PluginBadgeTone.official)
                        : null,
                    subtitle: agentPresetDescription(preset),
                    subtitleMaxLines: 2,
                    onTap: () => unawaited(_show(context, ref, preset)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PresetDocumentPage extends ConsumerWidget {
  const _PresetDocumentPage({required this.preset});

  final AgentPresetInfo preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final doc = ref.watch(agentPresetDocumentProvider(preset.id));
    final theme = Theme.of(context);
    return AppPage.list(
      title: agentPresetName(preset),
      subtitle: Text(preset.id, style: AppType.monoLabel()),
      children: [
        ListPageCard(
          children: [
            FeatureBlock(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: switch (doc) {
                AsyncData(:final value) => SelectableText(
                  value.content.isEmpty ? l10n.featuresEmptyDocument : value.content,
                  style: AppType.monoLabel(color: theme.colorScheme.onSurface).copyWith(fontSize: 12, height: 1.5),
                ),
                AsyncError(:final error) => Text(featureErrorText(l10n.featuresReadFailed, error)),
                _ => const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 24)),
              },
            ),
          ],
        ),
      ],
    );
  }
}
