import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart' show describeSettingsError;
import '../../state/features_state.dart';
import '../../state/hosts_state.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../settings/index/spots.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'feature_format.dart';
import 'feature_widgets.dart';

/// Writes the host's default for new conversations; null on success.
Future<String?> writePermissionDefault(DshClient client, String value, int revision) async {
  try {
    await client.setSetting('permission', ['defaultPreset'], value, expectedRevision: revision);
    return null;
  } catch (e) {
    debugPrint('Permission default failed: $e');
    return describeSettingsError(e);
  }
}

/// Full access and auto review skip confirmations: they ask first, like the
/// official picker.
Future<bool> confirmPermission(BuildContext context, String value) => switch (value) {
  'danger-full-access' => confirmRisk(context, RiskNotices.fullAccess),
  'auto' => confirmRisk(context, RiskNotices.autoReview),
  _ => Future.value(true),
};

class PermissionPage extends ConsumerStatefulWidget {
  const PermissionPage({super.key, this.sessionId});

  /// The conversation whose preset the first group switches; null shows
  /// only the default for new conversations.
  final String? sessionId;

  @override
  ConsumerState<PermissionPage> createState() => _PermissionPageState();
}

class _PermissionPageState extends ConsumerState<PermissionPage> {
  bool _busy = false;

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Full access (and auto review) skip confirmations: ask first, like the
  /// official picker.
  Future<bool> _confirm(String value) => confirmPermission(context, value);

  Future<void> _setCurrent(String value) async {
    final sessionId = widget.sessionId;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (sessionId == null || client == null || _busy) return;
    if (!await _confirm(value) || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await client.setPermissionPreset(sessionId, value);
      if (!result.success && mounted) _toast(context.l10n.featuresSwitchFailed);
    } catch (e) {
      if (mounted) _toast(featureErrorText(context.l10n.featuresSwitchFailed, e));
    } finally {
      ref.invalidate(permissionStateProvider(sessionId));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDefault(String value, int? revision) async {
    final owner = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final state = ref.read(permissionStateProvider(widget.sessionId)).value;
    final allowed = state?.defaultOptions ?? state?.options.where((o) => o.value != 'auto');
    if (client == null || _busy || revision == null || allowed?.any((o) => o.value == value) != true) return;
    if (!await _confirm(value) || !mounted || ref.read(activeHostProvider) != owner) return;
    setState(() => _busy = true);
    try {
      final problem = await writePermissionDefault(client, value, revision);
      if (problem != null && mounted) _toast(problem);
    } finally {
      ref.invalidate(permissionStateProvider(widget.sessionId));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetDefault(int revision) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || _busy) return;
    setState(() => _busy = true);
    try {
      await client.mutateSettings('permission', const [
        SettingsOp.unset(['defaultPreset']),
      ], expectedRevision: revision);
    } catch (error) {
      if (mounted) _toast(describeSettingsError(error));
    } finally {
      if (mounted) {
        ref.invalidate(permissionStateProvider(widget.sessionId));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connected = ref.watch(activeConnectionProvider).value != null;
    final state = ref.watch(permissionStateProvider(widget.sessionId));
    final value = state.value;

    List<Widget> options(List<PermissionOption> choices, String? selected, ValueChanged<String>? onPick) => [
      for (final o in choices)
        _PresetTile(
          title: permissionName(o.value, o.name),
          subtitle: permissionHint(o.value, o.description),
          selected: o.value == selected,
          onTap: _busy || onPick == null ? null : () => onPick(o.value),
        ),
    ];

    return AppPage.list(
      title: l10n.featuresPermissions,
      subtitle: Text(l10n.featuresPermissionsSubtitle),
      children: [
        if (!connected)
          const FeatureOffline()
        else if (value == null && state.hasError)
          FeatureMessage.error(
            title: l10n.featuresPermissionsReadFailed,
            error: state.error!,
            onRetry: () => ref.invalidate(permissionStateProvider(widget.sessionId)),
          )
        else if (value == null)
          const FeatureLoading()
        else ...[
          if (widget.sessionId != null && !value.invalidDefault) ...[
            ListPageCard(
              title: l10n.featuresCurrentChat,
              spot: Spots.permissionCurrent,
              children: options(value.options, value.current, (v) => unawaited(_setCurrent(v))),
            ),
            if (value.current == 'custom') FeatureNote(l10n.featuresPermissionCustomHint),
            const SizedBox(height: 24),
          ],
          if (value.invalidDefault)
            FeatureMessage(
              icon: AppIcons.permissions,
              title: l10n.featuresPermissionResetHint,
              action: switch (value.defaultRevision) {
                final revision? => (l10n.featuresPermissionResetDefault, () => unawaited(_resetDefault(revision))),
                null => null,
              },
            )
          else
            ListPageCard(
              title: l10n.featuresNewChatDefault,
              spot: Spots.permissionDefault,
              children: options(
                value.defaultOptions ?? value.options.where((o) => o.value != 'auto').toList(),
                value.hostDefault,
                value.defaultRevision == null ? null : (v) => unawaited(_setDefault(v, value.defaultRevision)),
              ),
            ),
        ],
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.title, required this.selected, required this.onTap, this.subtitle});

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ListPageRow(
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
        onTap: onTap,
        trailing: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: selected
              ? Icon(AppIcons.selected, key: const ValueKey(true), size: 22, color: scheme.primary)
              : const SizedBox.square(dimension: 22, key: ValueKey(false)),
        ),
      ),
    );
  }
}
