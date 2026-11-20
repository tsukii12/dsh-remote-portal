// 「Agent 循环」 and 「命令执行」: the parallel tool-call cap of `agent-loop` and
// the shell executor's limits (`bash-sandbox`, or `pwsh-sandbox` on Windows
// hosts), with the copy of `dsh-client-ui-settings-agent-loop` / `-shell`.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'namespace_copy.dart';
import 'schema_form.dart';

SchemaFieldSpec _field(String ns, String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));

class AgentLoopSettingsPage extends StatelessWidget {
  const AgentLoopSettingsPage({super.key});

  static const ns = 'agent-loop';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineAgentLoopTitle,
      namespaces: const [ns],
      builder: (context, settings) => schemaFormGroups([
        SchemaFormSection(fields: [_field(ns, 'maxParallelToolCalls')]),
      ], settings: settings),
    );
  }
}

class ShellSettingsPage extends StatelessWidget {
  const ShellSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineShellTitle,
      namespaces: const ['bash-sandbox', 'pwsh-sandbox'],
      builder: (context, settings) {
        final ns = settings.served('pwsh-sandbox') && !settings.served('bash-sandbox')
            ? 'pwsh-sandbox'
            : 'bash-sandbox';
        return schemaFormGroups([
          SchemaFormSection(fields: [_field(ns, 'timeoutMs'), _field(ns, 'maxOutputBytes')]),
          SchemaFormSection(
            title: l10n.commonMore,
            fields: [_field(ns, 'maxTimeoutMs'), _field(ns, 'maxSpillBytes'), _field(ns, 'graceMs')],
          ),
        ], settings: settings);
      },
    );
  }
}
