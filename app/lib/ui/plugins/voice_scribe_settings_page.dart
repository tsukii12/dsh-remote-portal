import 'dart:async';

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/voice_scribe_settings.dart';
import '../engine_settings/field_row.dart';
import '../engine_settings/field_sheets.dart';
import '../features/feature_widgets.dart';
import '../settings/settings_widgets.dart' show SettingsSection;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

String get voiceScribePageTitle => appL10n.voiceScribeTitle;

/// This route belongs to the connection that opened it. It never retargets a
/// surviving edit sheet to another host, even when the same client returns.
class VoiceScribeSettingsPage extends ConsumerStatefulWidget {
  const VoiceScribeSettingsPage({super.key, required this.source, required this.entryId});
  final HostConnection source;
  final String entryId;

  @override
  ConsumerState<VoiceScribeSettingsPage> createState() => _VoiceScribeSettingsPageState();
}

class _VoiceScribeSettingsPageState extends ConsumerState<VoiceScribeSettingsPage> {
  late final VoiceScribeSettingsController _controller;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _sourceLost = false;

  bool _matches(AsyncValue<HostConnection?> active) {
    final value = active.value;
    return !active.isLoading &&
        !active.hasError &&
        value != null &&
        identical(value.client, widget.source.client) &&
        value.hostId == widget.source.hostId &&
        value.kind == widget.source.kind;
  }

  bool _current() => mounted && !_sourceLost && _matches(ref.read(activeConnectionProvider));

  @override
  void initState() {
    super.initState();
    final client = widget.source.client;
    _controller = VoiceScribeSettingsController(
      VoiceScribeHttpTransport(client: client, entryId: widget.entryId, isCurrent: _current),
      _current,
    );
    ref.listenManual(activeConnectionProvider, (_, next) {
      if (!_matches(next)) {
        _sourceLost = true;
        _controller.invalidate();
      }
    });
    void reload() {
      _controller.invalidate();
      if (_current()) unawaited(_controller.refresh());
    }

    _subscriptions.add(
      client.pluginManagerEvents.listen((event) {
        if (event is PluginManagerChangedEvent) reload();
      }),
    );
    _subscriptions.add(client.mux.generations.listen((_) => reload()));
    _subscriptions.add(
      client.mux.states.listen((state) {
        if (state != DshConnectionState.connected) _controller.invalidate();
      }),
    );
    if (client.carrier is DshHttpCarrier && true) unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _controller.dispose();
    super.dispose();
  }

  void _edit(VoiceScribeField field) {
    final data = _controller.data;
    if (data == null) return;
    final generation = _controller.generation;
    final prompt = field == VoiceScribeField.polishPrompt;
    unawaited(
      showTextSheet(
        context,
        title: prompt ? appL10n.voiceScribePolishPrompt : appL10n.voiceScribeLanguage,
        meta: SchemaMeta(role: prompt ? 'textarea' : null, max: prompt ? 8000 : null),
        current: data.value(field),
        inherited: '',
        modified: data.value(field).isNotEmpty,
        onSubmit: (value) => _controller.save(generation, field, value),
        onReset: () => _controller.save(generation, field, ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeConnectionProvider);
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final data = _controller.data;
        final enabled = _current() && !_controller.loading && !_controller.saving;
        return AppPage.list(
          title: voiceScribePageTitle,
          subtitle: Text(widget.source.label),
          actions: [
            if (widget.source.client.carrier is DshHttpCarrier)
              IconButton(
                tooltip: appL10n.voiceScribeRefresh,
                icon: const Icon(AppIcons.refresh),
                onPressed: enabled ? () => unawaited(_controller.refresh()) : null,
              ),
          ],
          children: [
            if (!_current())
              FeatureMessage(icon: AppIcons.disconnected, title: appL10n.voiceScribeHostChanged)
            else if (widget.source.client.carrier is! DshHttpCarrier)
              FeatureMessage(
                icon: AppIcons.unsupported,
                title: voiceScribePageTitle,
                body: appL10n.voiceScribeUnsupported,
              )
            else if (data == null && _controller.error != null)
              FeatureMessage(
                icon: AppIcons.error,
                title: _controller.error!,
                action: (l10n.commonRetry, () => unawaited(_controller.refresh())),
              )
            else if (data == null)
              const FeatureLoading()
            else ...[
              SettingsSection(
                footer: _controller.error == null ? null : Text(_controller.error!),
                children: [
                  EngineFieldRow(
                    title: appL10n.voiceScribeLanguage,
                    value: data.language.isEmpty ? appL10n.voiceScribePluginDefault : data.language,
                    enabled: enabled,
                    onTap: () => _edit(VoiceScribeField.language),
                  ),
                  EngineFieldRow(
                    title: appL10n.voiceScribePolishPrompt,
                    value: data.polishPrompt.isEmpty ? appL10n.voiceScribeBuiltInPrompt : data.polishPrompt,
                    enabled: enabled,
                    onTap: () => _edit(VoiceScribeField.polishPrompt),
                  ),
                ],
              ),
              // What the plugin reads from its own config: shown, not edited here.
              if (data.providers.isNotEmpty)
                SettingsSection(
                  title: appL10n.voiceScribeProviders,
                  children: [
                    for (final provider in data.providers)
                      // The model gets the row's width; host and key share the line under it.
                      EngineFieldRow(
                        title: provider.model,
                        subtitle: [
                          if (Uri.tryParse(provider.url)?.host case final host? when host.isNotEmpty)
                            host
                          else if (provider.url.isNotEmpty)
                            provider.url,
                          provider.hasKey ? appL10n.voiceScribeKeySet : appL10n.voiceScribeNoKey,
                        ].join(' · '),
                      ),
                  ],
                ),
              SettingsSection(
                title: appL10n.voiceScribeHotwords,
                children: [
                  EngineFieldRow(
                    title: appL10n.voiceScribeHotwordRules(data.hotwordsRules),
                    subtitle: data.hotwordsError.isNotEmpty
                        ? data.hotwordsError
                        : data.hotwordsPath.isEmpty
                        ? null
                        : data.hotwordsPath,
                    subtitleColor: data.hotwordsError.isNotEmpty ? DshColors.of(context).danger : null,
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
