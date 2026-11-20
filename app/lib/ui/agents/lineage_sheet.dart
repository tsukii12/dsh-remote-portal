// The header's 「N 个子代理」 sheet (DSH Web opens the
// same catalog as a dropdown under its session header).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/feature_tile.dart';
import '../common/sheet_title_bar.dart';
import 'agent_widgets.dart';

/// The lineage under [sessionId] as a sheet; a row opens that conversation.
Future<void> showLineageSheet(BuildContext context, {required String sessionId}) {
  // Fresh activity for the rows (the list hints refresh on status events).
  ProviderScope.containerOf(context, listen: false).read(sessionsProvider.notifier).refresh().ignore();
  return showAppSheet<void>(context, isScrollControlled: true, builder: (_) => LineageSheet(sessionId: sessionId));
}

class LineageSheet extends ConsumerWidget {
  const LineageSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final nodes = ref.watch(subagentLineageProvider(sessionId));
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(nodes.isEmpty ? l10n.botsSubagents : lineageTitle(nodes)),
          if (lineageSubtitle(nodes) != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LineageSummary(nodes: nodes),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(bottom: bottom + 16),
              child: nodes.isEmpty
                  ? EmptyView(
                      art: FeatureTile(FeatureKind.subagents, size: FeatureTile.compact),
                      title: l10n.botsNoSubagents,
                      compact: true,
                    )
                  : SubagentTreeCard(
                      nodes: nodes,
                      margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                      onOpen: (node) {
                        selectSubagent(ref, node.address);
                        Navigator.of(context).pop();
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
