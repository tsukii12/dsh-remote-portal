// 渠道详情 (a detail page): what one custom provider is, whether it works (a cheap
// 「测试连接」: the endpoint's model listing with the stored key), its models, edit
// and delete.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers_state.dart';
import '../common/app_dialog.dart';
import '../common/expand_reveal.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'provider_form_page.dart';
import 'provider_model_page.dart';
import 'provider_widgets.dart';

/// Short protocol name for the hero's figures.
String _protocolShort(ProviderApi? api) => switch (api) {
  ProviderApi.openaiCompletions => 'OpenAI',
  ProviderApi.anthropicMessages => 'Anthropic',
  ProviderApi.openaiResponses => 'Responses',
  null => '—',
};

class ProviderDetailPage extends ConsumerStatefulWidget {
  const ProviderDetailPage({super.key, required this.providerId});

  /// Looked up in the live read-back, so edits made elsewhere show up.
  final String providerId;

  @override
  ConsumerState<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

/// Outcome of 「测试连接」.
sealed class _Probe {
  const _Probe();
}

class _Testing extends _Probe {
  const _Testing();
}

class _Passed extends _Probe {
  const _Passed(this.count);
  final int count;
}

class _Failed extends _Probe {
  const _Failed(this.message);
  final String message;
}

class _ProviderDetailPageState extends ConsumerState<ProviderDetailPage> {
  _Probe? _probe;
  bool _deleting = false;

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /// 模型设置, saved on the spot (only the `models` list is written).
  void _editModel(CustomProvider provider, ProviderModelSpec model) => _push(
    ProviderModelPage(
      model: model,
      defaults: provider.defaults,
      onSave: (edited) => ref.read(providerActionsProvider).saveModel(provider, edited),
    ),
  );

  Future<void> _test(CustomProvider provider) async {
    setState(() => _probe = const _Testing());
    try {
      final count = await ref.read(providerActionsProvider).test(provider);
      if (mounted) setState(() => _probe = _Passed(count));
    } catch (error) {
      if (mounted) setState(() => _probe = _Failed(describeProviderError(error)));
    }
  }

  Future<void> _delete(CustomProvider provider) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.engineProviderDeleteTitle(provider.displayName)),
        content: Text(context.l10n.engineProviderDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(providerActionsProvider).delete(provider);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.l10n.engineProviderDeleteFailed(describeProviderError(error)))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(customProvidersProvider);
    final snapshot = async.value;
    final provider = snapshot?.byId(widget.providerId);
    if (snapshot == null || provider == null) {
      return AppPage.list(
        title: l10n.engineProviderTitle,
        children: [
          if (snapshot == null && async.isLoading)
            const QuietSpinner()
          else if (snapshot == null && async.hasError)
            FeatureMessage(
              icon: AppIcons.error,
              title: l10n.engineProviderReadFailed,
              body: describeProviderError(async.error!),
              action: (l10n.commonRetry, () => ref.invalidate(customProvidersProvider)),
            )
          else if (snapshot == null)
            const FeatureOffline()
          else
            EmptyView(
              icon: AppIcons.providers,
              title: l10n.engineProviderGone,
              padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
            ),
        ],
      );
    }
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final health = snapshot.healthOf(provider);
    final view = ProviderHealthView.of(health);
    final keyStored = snapshot.keyStored(provider);
    final diagnostic = snapshot.diagnostics[provider.id];
    final canEdit = provider.editable && snapshot.writable;
    final canDelete = provider.removable && snapshot.writable && !_deleting;
    const gap = SizedBox(height: 24);

    return AppPage(
      title: provider.displayName,
      actions: [
        if (canEdit)
          GlassIconButton(
            icon: AppIcons.edit,
            tooltip: l10n.commonEdit,
            onPressed: () => _push(ProviderFormPage(existing: provider)),
          ),
      ],
      hero: PageHero(
        leading: Monogram(provider.displayName, size: 56),
        title: provider.displayName,
        subtitle: Row(
          children: [
            ProviderDot(view.tone),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                [view.label, if (provider.host.isNotEmpty) provider.host].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        stats: [
          ('${provider.models.length}', l10n.engineModelTitle),
          (_protocolShort(provider.api), l10n.engineProviderProtocol),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            ExpandReveal(
              open: health == ProviderHealth.missingKey && canEdit,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _push(ProviderFormPage(existing: provider)),
                    child: Text(l10n.engineProviderEnterKey),
                  ),
                ),
              ),
            ),
            if (diagnostic != null) ...[
              ListPageCard(
                title: l10n.engineProviderIssues,
                children: [
                  ListPageRow(
                    icon: AppIcons.error,
                    iconColor: colors.danger,
                    title: l10n.engineProviderRejectedConfig,
                    subtitle: diagnostic,
                    subtitleMaxLines: 4,
                  ),
                ],
              ),
              gap,
            ],
            ListPageCard(
              title: l10n.engineProviderConnection,
              children: [
                ListPageRow(
                  icon: AppIcons.link,
                  title: 'Base URL',
                  subtitle: provider.baseUrl.isEmpty ? l10n.engineProviderDefaultUrl : provider.baseUrl,
                  subtitleMaxLines: 2,
                ),
                ListPageRow(
                  icon: AppIcons.apiKey,
                  title: 'API Key',
                  value: provider.apiKeyEnv == null
                      ? l10n.engineProviderKeyNotRequired
                      : (keyStored ? l10n.commonSaved : l10n.commonNotSet),
                  onTap: canEdit ? () => _push(ProviderFormPage(existing: provider)) : null,
                ),
                _TestRow(probe: _probe, onTap: _probe is _Testing ? null : () => _test(provider)),
              ],
            ),
            gap,
            ListPageCard(
              title: l10n.engineProviderModelCount(provider.models.length),
              children: [
                for (final model in provider.models)
                  ListPageRow(
                    icon: AppIcons.modelItem,
                    title: model.label,
                    subtitle: switch (modelSummary(context, model, defaults: provider.defaults)) {
                      '' => null,
                      final summary => summary,
                    },
                    onTap: canEdit ? () => _editModel(provider, model) : null,
                  ),
                if (provider.models.isEmpty)
                  ListPageRow(
                    icon: AppIcons.modelItem,
                    iconColor: colors.textTertiary,
                    title: l10n.engineProviderNoModels,
                  ),
              ],
            ),
            if (!provider.editable) FeatureNote(l10n.engineProviderWebConfigured),
            gap,
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.danger),
                onPressed: canDelete ? () => _delete(provider) : null,
                icon: const Icon(AppIcons.delete, size: 19),
                label: Text(l10n.engineProviderDelete),
              ),
            ),
            if (!provider.removable)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  l10n.engineProviderConfigFile,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 「测试连接」 and its outcome on the second line.
class _TestRow extends StatelessWidget {
  const _TestRow({required this.probe, required this.onTap});

  final _Probe? probe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final probe = this.probe;
    return ListPageRow(
      icon: AppIcons.testConnection,
      title: probe is _Testing ? l10n.engineProviderTesting : l10n.engineProviderTestConnection,
      subtitle: switch (probe) {
        _Passed(:final count) => l10n.engineProviderTestPassed(count),
        _Failed(:final message) => message,
        _ => null,
      },
      subtitleColor: switch (probe) {
        _Passed() => colors.success,
        _Failed() => colors.danger,
        _ => null,
      },
      subtitleMaxLines: 2,
      chevron: false,
      trailing: probe is _Testing
          ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: colors.textTertiary))
          : null,
      onTap: onTap,
    );
  }
}
