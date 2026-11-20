// Asking whether a native plugin may hear the person speak (v1.2 `voice`,
// docs/design/native-plugins-protocol.md §11.4). Asked once per host and
// plugin, before Android's own microphone permission; 「不允许」 is remembered, and
// the plugin's 「听你开口」 switch changes it later.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_capabilities.dart';
import '../../../plugins/native/native_state.dart';
import '../../../state/hosts_state.dart';
import '../../common/app_dialog.dart';

/// True when [package] may listen: allowed before, or allowed now. A
/// dismissed question is no answer (asked again next time).
Future<bool> askNativeVoiceConsent(BuildContext context, WidgetRef ref, String package) async {
  final host = ref.read(activeHostProvider);
  final consents = ref.read(nativeVoiceConsentProvider.notifier);
  final known = consents.of(host, package);
  if (known != null) return known;
  if (!context.mounted) return false;
  final l10n = context.l10n;
  final title = ref.read(nativePluginTitleProvider(package));
  final answer = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.plugslotsVoiceAsk(title)),
      content: Text(l10n.plugslotsVoiceWhen),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.plugslotsVoiceDeny)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.plugslotsAllow)),
      ],
    ),
  );
  if (answer == null) return false;
  await consents.set(host, package, answer);
  return answer;
}
