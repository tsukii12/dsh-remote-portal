// 组合预览 (STAGE3-APP-INTEGRATION §5): what the packs compose into for a
// real character (and chat), with the scope being edited as proposed.
// Nothing is saved or run; definition diagnostics and composition
// conflicts stay apart, and an unvalidated current value never reads as fine.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_packs.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import 'tavern_pack_widgets.dart';

class TavernPackPreviewPage extends ConsumerStatefulWidget {
  const TavernPackPreviewPage({super.key, required this.gameplayContext, this.proposed = const []});

  final TavernGameplayContext gameplayContext;
  final List<TavernPackScopePreview> proposed;

  static Route<void> route(TavernGameplayContext context, {List<TavernPackScopePreview> proposed = const []}) =>
      MaterialPageRoute<void>(
        builder: (_) => TavernPackPreviewPage(gameplayContext: context, proposed: proposed),
      );

  @override
  ConsumerState<TavernPackPreviewPage> createState() => _TavernPackPreviewPageState();
}

class _TavernPackPreviewPageState extends ConsumerState<TavernPackPreviewPage> {
  late final Future<TavernGameplayResolution> _resolution = ref
      .read(tavernProvider)
      .resolveGameplayConfig(
        widget.gameplayContext,
        proposedScopes: widget.proposed,
        validateCurrentState: widget.gameplayContext.chatId != null,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<TavernGameplayResolution>(
      future: _resolution,
      builder: (context, snap) => AppPage.list(
        title: l10n.tavernPackPreview,
        subtitle: Text(l10n.tavernPackPreviewSubtitle),
        children: switch (snap) {
          AsyncSnapshot(:final error?) => [
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(child: Text(tavernPackErrorText(l10n, error))),
            ),
          ],
          AsyncSnapshot(data: final r?) => _sections(l10n, r),
          _ => const [
            Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: QuietSpinner()),
            ),
          ],
        },
      ),
    );
  }

  List<Widget> _sections(L10n l10n, TavernGameplayResolution r) {
    final state = r.currentState;
    return [
      SettingsSection(
        key: const ValueKey('tavern-pack-preview-sources'),
        title: l10n.tavernPackPreviewSources,
        children: [for (final s in r.sources) _Line(_plain(s))],
      ),
      SettingsSection(
        key: const ValueKey('tavern-pack-preview-definitions'),
        title: l10n.tavernPackPreviewDefinitions,
        children: [
          for (final d in r.definitions)
            switch ([for (final i in d['issues'] as List<Object?>? ?? const []) i! as Map<String, Object?>]) {
              final issues => SettingsTile(
                tinted: false,
                title: '${d['domain'] ?? d['path'] ?? ''}',
                subtitle: _plain({
                  for (final e in d.entries)
                    if (e.key != 'domain' && e.key != 'path') e.key: e.value,
                }),
                value: issues.isEmpty ? null : Text(l10n.tavernPackIssueCount(issues.length)),
                chevron: issues.isNotEmpty,
                onTap: issues.isEmpty
                    ? null
                    : () => unawaited(
                        showTavernPackIssues(context, title: '${d['domain'] ?? d['path']}', issues: issues),
                      ),
              ),
            },
        ],
      ),
      SettingsSection(
        key: const ValueKey('tavern-pack-preview-conflicts'),
        title: l10n.tavernPackPreviewConflicts,
        children: r.conflicts.isEmpty
            ? [_Line(l10n.tavernPackNothingNoted)]
            : [for (final c in r.conflicts) _Padded(TavernPackIssueText(c))],
      ),
      if (r.fieldSources.isNotEmpty)
        SettingsSection(
          key: const ValueKey('tavern-pack-preview-fields'),
          title: l10n.tavernPackPreviewFields,
          children: [for (final f in r.fieldSources) _Line(_plain(f))],
        ),
      if (r.resources.isNotEmpty)
        SettingsSection(
          key: const ValueKey('tavern-pack-preview-resources'),
          title: l10n.tavernPackResources,
          children: [for (final res in r.resources) _Line(_plain(res))],
        ),
      if (widget.gameplayContext.chatId != null)
        SettingsSection(
          key: const ValueKey('tavern-pack-preview-state'),
          title: l10n.tavernPackPreviewState,
          children: [
            _Line(
              state == null
                  ? l10n.tavernPackStateUnavailable
                  : !state.validated
                  ? l10n.tavernPackStateNotValidated
                  : state.issues.isEmpty
                  ? l10n.tavernPackStateValid
                  : l10n.tavernPackStateInvalid,
            ),
            if (state != null) ...[
              if (!state.valueExists) _Line(l10n.tavernPackStateMissing),
              for (final issue in state.issues) _Padded(TavernPackIssueText(issue)),
            ],
          ],
        ),
      _Line(l10n.tavernPackPreviewNote),
    ];
  }

  /// A row's plain fields as `key: value`, the nested ones left to their
  /// own sections.
  static String _plain(Map<String, Object?> row) => [
    for (final e in row.entries)
      if (e.value case final v? when v is! Map && v is! List)
        '${e.key}: $v'
      else if (e.value case {'installedPackId': _, 'packVersion': final version})
        '${e.key}: $version'
      // A field's winner and the sources it shadowed say where it came from.
      else if (e.value case final Map<String, Object?> source when e.key == 'winner')
        '${e.key}: (${_plain(source)})'
      else if (e.value case final List<Object?> sources when e.key == 'shadowed' && sources.isNotEmpty)
        '${e.key}: ${[for (final s in sources.whereType<Map<String, Object?>>()) '(${_plain(s)})'].join(' ')}',
  ].join(' · ');
}

class _Line extends StatelessWidget {
  const _Line(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      _Padded(SelectableText(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5)));
}

class _Padded extends StatelessWidget {
  const _Padded(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: child);
}
