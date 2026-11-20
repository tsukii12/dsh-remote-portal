// 历史版本 (STAGE2-IMPLEMENTATION-R3 §4.3): the versions a card or book had,
// newest first. Going back to one saves it again as a new version; nothing
// after it is lost, and media or chats are not touched.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_authoring.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../bots/bot_format.dart' show shortTime;
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class TavernDraftHistoryPage extends ConsumerStatefulWidget {
  const TavernDraftHistoryPage({super.key, required this.source});

  final TavernAuthoringSource source;

  static Route<void> route(TavernAuthoringSource source) =>
      MaterialPageRoute<void>(builder: (_) => TavernDraftHistoryPage(source: source));

  @override
  ConsumerState<TavernDraftHistoryPage> createState() => _TavernDraftHistoryPageState();
}

class _TavernDraftHistoryPageState extends ConsumerState<TavernDraftHistoryPage> {
  late Future<List<TavernAuthoringRevisionSummary>> _versions = _read();

  /// A restore under way: its id, kept until the engine answers.
  String? _operation;
  bool _busy = false;

  Future<List<TavernAuthoringRevisionSummary>> _read() =>
      ref.read(tavernProvider).listAuthoringRevisions(widget.source.physicalResourceId);

  Future<void> _restore(TavernAuthoringRevisionSummary version, TavernAuthoringRevisionSummary current) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.tavernDraftRestoreTitle(version.revision)),
        content: Text(l10n.tavernDraftRestoreBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.tavernDraftRestore)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final operation = _operation ??= tavernNewId();
    setState(() => _busy = true);
    String notice;
    try {
      final receipt = await ref
          .read(tavernProvider)
          .restoreAuthoringRevision(
            widget.source.physicalResourceId,
            revision: TavernAuthorityRevision(domainId: version.domainId, revision: version.revision),
            expectedAuthorityRevision: TavernAuthorityRevision(domainId: current.domainId, revision: current.revision),
            operationId: operation,
          );
      _operation = null;
      notice = switch (receipt.committed) {
        true => l10n.tavernDraftRestored(version.revision),
        false => l10n.tavernDraftNotApplied(receipt.issue?.message ?? ''),
        null => l10n.tavernDraftUnconfirmed,
      };
      ref.invalidate(tavernCharacterDetailProvider);
    } on TavernAuthoringException catch (e) {
      _operation = null;
      notice = e.code == 'authority_conflict' ? l10n.tavernDraftRestoreMoved : e.message;
    } on Object catch (e) {
      notice = l10n.tavernDraftApplyUnknown('$e'.split('\n').first);
    }
    if (!mounted) return;
    showBriefNotice(context, notice);
    setState(() {
      _busy = false;
      _versions = _read();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<List<TavernAuthoringRevisionSummary>>(
      future: _versions,
      builder: (context, snapshot) {
        final versions = snapshot.data;
        return AppPage.list(
          title: l10n.tavernDraftHistory,
          subtitle: Text(tavernDraftSourceName(l10n, widget.source)),
          children: [
            if (versions == null && !snapshot.hasError)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: QuietSpinner()),
              )
            else if (versions == null || versions.isEmpty)
              Padding(
                key: const ValueKey('tavern-draft-history-empty'),
                padding: const EdgeInsets.only(top: 48),
                child: EmptyView(
                  icon: AppIcons.history,
                  title: l10n.tavernDraftHistoryEmpty,
                  message: snapshot.hasError ? '${snapshot.error}' : null,
                  compact: true,
                ),
              )
            else
              SettingsSection(
                key: const ValueKey('tavern-draft-history'),
                footer: Text(l10n.tavernDraftHistoryNote),
                children: [
                  for (final (i, v) in versions.indexed)
                    SettingsTile(
                      key: ValueKey('tavern-draft-version-${v.revision}'),
                      icon: i == 0 ? AppIcons.done : AppIcons.history,
                      tinted: false,
                      title: l10n.tavernDraftVersion(v.revision),
                      subtitle: i == 0 ? l10n.tavernDraftVersionCurrent : null,
                      value: Text(shortTime(v.at.toLocal())),
                      chevron: false,
                      onTap: i == 0 || _busy ? null : () => unawaited(_restore(v, versions.first)),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}
