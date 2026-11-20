// 「通用设置」: the preferences the official General settings keep on the
// engine — the code work view (`ui-settings`), work details, collapse timing,
// performance & usage and link opening (`ui-chat`), the busy-Enter behaviour
// (`ui-conversation`) — all of which only the web client reads, hence the
// 网页版 groups — and the session log upload (`session-log-deepseek`), which
// the engine itself honours. Language is left out: the app has its own.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'namespace_copy.dart';
import 'schema_form.dart';

SchemaFieldSpec _field(String ns, String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));

class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  static const namespaces = ['ui-settings', 'ui-chat', 'ui-conversation', 'session-log-deepseek'];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineGeneralTitle,
      namespaces: namespaces,
      missingTitle: l10n.engineGeneralMissing,
      missingBody: l10n.engineSettingsVersionRequired,
      builder: (context, settings) => schemaFormGroups([
        SchemaFormSection(
          title: l10n.engineGeneralWebDisplay,
          footer: l10n.engineGeneralWebOnlyHint,
          fields: [
            _field('ui-settings', 'enabled'),
            _field('ui-chat', 'transcriptView'),
            _field('ui-chat', 'collapseTiming'),
            _field('ui-chat', 'performanceUsage'),
          ],
        ),
        SchemaFormSection(
          title: l10n.engineGeneralWebSending,
          footer: l10n.engineGeneralWebOnlyHint,
          fields: [_field('ui-conversation', 'busyEnter'), _field('ui-chat', 'linkOpening')],
        ),
        if (settings.served('session-log-deepseek'))
          SchemaFormSection(title: l10n.engineGeneralData, fields: [_field('session-log-deepseek', 'enabled')]),
      ], settings: settings),
    );
  }
}
