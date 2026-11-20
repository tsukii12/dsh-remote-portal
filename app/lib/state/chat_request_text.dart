import 'package:dsh_client/dsh_client.dart';

import '../l10n/host_text.dart';
import '../l10n/l10n.dart';
import '../ui/chat/secret_mask.dart';

String _masked(String text) => maskSecrets(text, mark: '•').replaceAll(RegExp('•{6,}'), '••••••');

String? snippet(String? text, {int max = 120}) {
  if (text == null) return null;
  final flat = _masked(text)
      .replaceAll(RegExp(r'```[a-zA-Z0-9_-]*'), ' ')
      .replaceAll(RegExp(r'^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (flat.isEmpty) return null;
  final chars = flat.runes.toList();
  if (chars.length <= max) return flat;
  return '${String.fromCharCodes(chars.take(max)).trimRight()}…';
}

String approvalText(ApprovalRequest request) {
  final action = switch (request.toolName) {
    'bash' || 'pwsh' => appL10n.stateRunCommand,
    'write' => appL10n.stateWriteFile,
    'edit' || 'str_replace_editor' => appL10n.stateEditFile,
    'web_fetch' => appL10n.stateOpenPage,
    'web_search' => appL10n.stateWebSearch,
    final name => appL10n.stateAlertUseTool(name),
  };
  final reason = snippet(
    localizedHostText(request.displayReason, locale: AppLocale.current.toLanguageTag(), fallback: request.reason),
    max: 90,
  );
  return reason == null ? appL10n.stateAlertApprovalAction(action) : appL10n.stateAlertApprovalReason(action, reason);
}

String questionText(UserQuestionRequest request) {
  final first = request.questions.isEmpty ? null : snippet(request.questions.first.question, max: 90);
  if (first == null) return appL10n.stateAlertQuestion;
  return request.questions.length > 1
      ? appL10n.stateAlertQuestions(first, request.questions.length)
      : appL10n.stateAlertQuestionText(first);
}
