import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/model_defaults_state.dart';
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../chat/model_sheet.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../features/feature_widgets.dart';
import '../theme/app_icons.dart';

/// Host settings only: changing these defaults never selects a model in the
/// conversation currently open behind the settings page.
class NewChatDefaultsCard extends ConsumerStatefulWidget {
  const NewChatDefaultsCard({super.key});

  @override
  ConsumerState<NewChatDefaultsCard> createState() => _NewChatDefaultsCardState();
}

class _NewChatDefaultsCardState extends ConsumerState<NewChatDefaultsCard> {
  bool _saving = false;
  String? _error;

  Future<void> _save(EngineSettings snapshot, ModelSelection selection, bool? remember) async {
    if (_saving) return;
    final controller = ref.read(engineSettingsProvider.notifier);
    final editor = controller.edit(snapshot);
    if (!editor.active || ref.read(readListLiveConnectionProvider) == null) return;
    final current = ref.read(engineSettingsProvider);
    if (current.isLoading || current.hasError || current.value == null) return;
    if (current.value![defaultModelSettingsNs]?.revision != snapshot[defaultModelSettingsNs]?.revision) {
      setState(() => _error = context.l10n.stateSettingsRefreshed);
      return;
    }
    if (!canEditDefaultModel(current.value!) || remember != null && !canEditDefaultModelMode(current.value!)) return;
    if (!isValidModelSelection(ref.read(currentModelCatalogProvider), selection)) {
      setState(() => _error = context.l10n.engineNewChatDefaultsSelectionUnavailable);
      return;
    }
    if (selection.reasoningEffort == null && current.value!.inheritedOf(defaultModelEffortField) != null) {
      setState(() => _error = context.l10n.engineNewChatDefaultsInheritedEffort);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final fields = [...defaultModelSelectionFields, if (remember != null) defaultModelRememberField];
      final ok = await editor.write(
        defaultModelSettingsNs,
        defaultModelOps(selection, rememberLastSelection: remember),
        fields: fields,
      );
      if (!mounted) return;
      if (!editor.active) {
        setState(() => _error = context.l10n.engineSettingsHostChanged);
        return;
      }
      if (!ok) {
        final settings = ref.read(engineSettingsProvider).value;
        setState(() => _error = settings?.errorOf(defaultModelIdField) ?? context.l10n.commonSaveFailed);
        return;
      }
      // The mutation response confirms the write; re-read the resolved layers
      // too. Inherited effort or another client's edit must not look saved.
      await controller.refresh();
      if (!mounted) return;
      if (!editor.active) {
        setState(() => _error = context.l10n.engineSettingsHostChanged);
        return;
      }
      final confirmed = ref.read(engineSettingsProvider).value;
      final matches =
          confirmed != null &&
          jsonEquals(defaultModelSelection(confirmed)?.toJson(), selection.toJson()) &&
          (remember == null || confirmed.valueOf(defaultModelRememberField) == remember);
      if (!matches) setState(() => _error = context.l10n.engineNewChatDefaultsUnconfirmed);
      ref.invalidate(modelCatalogProvider);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.engineNewChatDefaultsUnconfirmed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick(EngineSettings snapshot, ModelSelection? current, bool? remember) async {
    final editor = ref.read(engineSettingsProvider.notifier).edit(snapshot);
    ModelSelection? picked;
    await showModelSheet(
      context,
      current: current,
      confirmSelection: true,
      onSelected: (selection) => picked = selection,
    );
    if (!mounted || picked == null) return;
    if (!editor.active) {
      setState(() => _error = context.l10n.engineSettingsHostChanged);
      return;
    }
    await _save(snapshot, picked!, remember);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(engineSettingsProvider);
    final connection = ref.watch(readListLiveConnectionProvider);
    final catalog = ref.watch(currentModelCatalogProvider);
    final catalogAsync = ref.watch(modelCatalogProvider);
    final settings = async.value;
    final active =
        settings != null &&
        !async.isLoading &&
        !async.hasError &&
        connection != null &&
        ref.read(engineSettingsProvider.notifier).edit(settings).active;
    final selection = active ? defaultModelSelection(settings) : null;
    final modeSupported = active && supportsDefaultModelMode(settings);
    final remember = !modeSupported || settings.valueOf(defaultModelRememberField) != false;
    final writable = active && canEditDefaultModel(settings) && (!modeSupported || canEditDefaultModelMode(settings));
    final editable = writable && !_saving;
    final modeEditable = editable && isValidModelSelection(catalog, selection);
    final available = findModel(catalog, selection);
    final description = selection == null
        ? l10n.viewModelSelect
        : [
            available?.name ?? '${selection.provider} / ${selection.model}',
            if (selection.reasoningEffort case final effort?) effortLabel(effort),
          ].join(' · ');
    final reason = connection == null
        ? l10n.engineProvidersStartEngine
        : async.isLoading
        ? l10n.stateLoading
        : async.hasError
        ? l10n.engineSettingsReadFailed
        : !active ||
              !settings.served(defaultModelSettingsNs) ||
              defaultModelSelectionFields.any((field) => settings.nodeOf(field)?.effective.type != 'string')
        ? l10n.engineNewChatDefaultsUnsupported
        : !writable
        ? l10n.engineProvidersReadOnly
        : catalogAsync.hasError
        ? l10n.viewModelLoadFailed
        : catalog == null
        ? l10n.stateLoading
        : selection != null && !isValidModelSelection(catalog, selection)
        ? l10n.engineNewChatDefaultsSelectionUnavailable
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListPageCard(
            title: remember ? l10n.engineNewChatDefaultsLast : l10n.engineNewChatDefaultsFixed,
            children: [
              if (modeSupported)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SegmentedPill<bool>(
                    height: 40,
                    segments: [
                      PillSegment(true, l10n.engineNewChatUseLast),
                      PillSegment(false, l10n.engineNewChatUseFixed),
                    ],
                    selected: remember,
                    onChanged: !modeEditable || selection == null ? null : (value) => _save(settings, selection, value),
                  ),
                ),
              ListPageRow(
                icon: AppIcons.model,
                title: description,
                titleMaxLines: 2,
                subtitle: _saving ? l10n.engineNewChatDefaultsSaving : reason,
                subtitleMaxLines: 2,
                trailing: async.hasError || catalogAsync.hasError || _error != null
                    ? IconButton(
                        tooltip: l10n.commonRetry,
                        icon: const Icon(AppIcons.refresh),
                        onPressed: _saving
                            ? null
                            : () {
                                setState(() => _error = null);
                                ref.invalidate(engineSettingsProvider);
                                ref.invalidate(modelCatalogProvider);
                              },
                      )
                    : null,
                onTap: editable && catalog != null
                    ? () => _pick(settings, selection, modeSupported ? remember : null)
                    : null,
              ),
            ],
          ),
          FeatureNote(l10n.engineNewChatDefaultsHint),
          if (active && !modeSupported) FeatureNote(l10n.engineNewChatDefaultsLegacy),
          if (_error case final error?) FeatureNote(error),
        ],
      ),
    );
  }
}
