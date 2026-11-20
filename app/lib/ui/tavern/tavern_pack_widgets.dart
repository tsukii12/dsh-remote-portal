// What the 玩法包 pages share: asking before a step that sticks, a list of
// diagnostics in a sheet, and making a character from a pack's cast.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';

Future<bool> tavernPackConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.commonCancel)),
        TextButton(
          key: const ValueKey('tavern-pack-confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Diagnostics as lines, the blocking ones marked; [note] above them.
Future<void> showTavernPackIssues(
  BuildContext context, {
  required String title,
  required List<Map<String, Object?>> issues,
  String? note,
}) => showAppSheet<void>(
  context,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(title),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
              children: [
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(note, style: Theme.of(sheet).textTheme.bodySmall),
                  ),
                for (final issue in issues) TavernPackIssueText(issue),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
);

/// One diagnostic line; a blocking one in the error colour.
class TavernPackIssueText extends StatelessWidget {
  const TavernPackIssueText(this.issue, {super.key});

  final Map<String, Object?> issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocking = tavernPackIssueBlocking(issue);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SelectableText(
        '${blocking ? '✕ ' : '· '}${tavernPackIssueLine(issue)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: blocking ? theme.colorScheme.error : DshColors.of(context).textTertiary,
          height: 1.5,
        ),
      ),
    );
  }
}

/// Imports whose outcome is not known yet, by pack version and cast id: the
/// next try is the same operation, never a second character.
final _unresolvedCastImports = <String, ({String operationId, String? domainId})>{};

/// Makes a new character from [cast] of the pack version [packRef], after
/// asking. The mapping when it was adopted, else null (said why).
Future<TavernCastMapping?> importTavernPackCast(
  BuildContext context,
  WidgetRef ref,
  TavernPackVersionRef packRef,
  TavernPackCast cast,
) async {
  final l10n = context.l10n;
  final ok = await tavernPackConfirm(
    context,
    title: l10n.tavernPackCastImportTitle(cast.name),
    message: l10n.tavernPackCastImportNote,
    action: l10n.tavernPackCastImportAction,
  );
  if (!ok || !context.mounted) return null;
  final tavern = ref.read(tavernProvider);
  final key = '${packRef.installedPackId}\u0000${packRef.packVersion}\u0000${cast.resource}\u0000${cast.localId}';
  final intent = _unresolvedCastImports[key] ??= (operationId: tavernNewId(), domainId: null);
  TavernCastImportResult result;
  try {
    result = await tavern.importDshgoCastMember(
      tavernPackCastSource(packRef, cast),
      cast.localId,
      operationId: intent.operationId,
      domainId: intent.domainId,
    );
    // Not known yet: the history of this very operation says; a later try
    // goes again in the same domain.
    if (result.receipt.committed == null) {
      final domainId = result.receipt.outcome.domainId;
      _unresolvedCastImports[key] = (operationId: intent.operationId, domainId: domainId);
      result = await tavern.readDshgoCastImport(domainId, intent.operationId) ?? result;
    }
  } on TavernGameplayException catch (e) {
    // Refused: nothing was made; a new try is a new intent.
    _unresolvedCastImports.remove(key);
    if (context.mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    return null;
  } on Object catch (e) {
    if (context.mounted) showBriefNotice(context, tavernPackErrorText(l10n, e));
    return null;
  }
  if (result.receipt.committed != null) _unresolvedCastImports.remove(key);
  if (!context.mounted) return result.mapping;
  switch (result.receipt.committed) {
    case true:
      ref.invalidate(tavernCharactersProvider);
      showBriefNotice(context, l10n.tavernPackCastImported(cast.name));
      // Made, with something to know (media that did not come along).
      if (result.receipt.issues.isNotEmpty) {
        unawaited(
          showTavernPackIssues(
            context,
            title: l10n.tavernPackCastImported(cast.name),
            issues: [
              for (final issue in result.receipt.issues) {'type': issue.type, 'message': issue.message},
            ],
          ),
        );
      }
    case false:
      unawaited(
        showTavernPackIssues(
          context,
          title: l10n.tavernPackCastNotAdopted,
          issues: [
            for (final issue in [?result.receipt.outcome.issue, ...result.receipt.issues])
              {'type': issue.type, 'message': issue.message},
          ],
        ),
      );
    case null:
      showBriefNotice(context, l10n.tavernPackCastUnknown(result.receipt.outcome.state.name));
  }
  return result.mapping;
}
