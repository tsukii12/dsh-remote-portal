// 资源库 › 正则 › 试一下 (docs/design/roleplay-ui §9): one rule tried on a
// piece of text, its result shown before and after. It runs through the
// engine's protected display path (its own worker, with the engine's time
// and size limits), so a pattern that never ends cannot hang the page.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';

class TavernRegexTestPage extends StatefulWidget {
  const TavernRegexTestPage({super.key, required this.script});

  final TavernRegexScript script;

  static Route<void> route(TavernRegexScript script) =>
      MaterialPageRoute<void>(builder: (_) => TavernRegexTestPage(script: script));

  @override
  State<TavernRegexTestPage> createState() => _TavernRegexTestPageState();
}

class _TavernRegexTestPageState extends State<TavernRegexTestPage> {
  final _text = TextEditingController();

  /// Made on the first try, closed with the page.
  RegexWorker? _worker;

  RegexDisplayResult? _result;
  bool _busy = false;
  String? _error;

  /// Bumped per try; a slower, older answer is dropped.
  int _ticket = 0;

  @override
  void dispose() {
    _text.dispose();
    unawaited(_worker?.close());
    super.dispose();
  }

  /// The rule as it is, but on, and run on any text: where it usually
  /// applies (your lines, replies, depth) does not matter for a try.
  RegexScript get _rule => RegexScript.fromJson({
    ...widget.script.raw,
    'disabled': false,
    'markdownOnly': true,
    'promptOnly': false,
    'placement': const [RegexPlacement.aiOutput],
    'minDepth': null,
    'maxDepth': null,
  });

  Future<void> _try() async {
    final ticket = ++_ticket;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await RegexEngine(globalScripts: [_rule])
          .applyDisplay(_text.text, placement: RegexPlacement.aiOutput, worker: _worker ??= RegexWorker());
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _busy = false;
        _result = result;
      });
    } on Object catch (e) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _busy = false;
        _result = null;
        _error = l10n.tavernRegexTestFailed('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final raw = widget.script.raw;
    final find = '${raw['findRegex'] ?? ''}';
    final replace = '${raw['replaceString'] ?? ''}';
    final code = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', height: 1.5);
    final note = theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5);
    final result = _result;
    return AppPage.list(
      title: l10n.tavernRegexTest,
      children: [
        SettingsSection(
          footer: Text(
            [l10n.tavernRegexTestNote, if ('$find$replace'.contains('{{')) l10n.tavernRegexTestMacros].join('\n'),
          ),
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.tavernRegexTestFind,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: SelectableText(find, key: const ValueKey('tavern-regex-test-find'), style: code),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.tavernRegexTestReplace,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: SelectableText(replace, style: code),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.tavernRegexTestInput,
                  child: TextField(
                    key: const ValueKey('tavern-regex-test-input'),
                    controller: _text,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(hintText: l10n.tavernRegexTestHint),
                  ),
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('tavern-regex-test-run'),
              onPressed: _busy ? null : () => unawaited(_try()),
              child: Text(l10n.tavernRegexTest),
            ),
          ),
        ),
        if (_busy)
          const QuietSpinner()
        else if (_error case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
            child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
          )
        else if (result != null) ...[
          // A rule the engine had to skip (too slow, too much, not valid) says why.
          for (final warning in result.warnings)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: Text(warning.message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
            ),
          if (result.replacements == 0 && result.warnings.isEmpty)
            Padding(
              key: const ValueKey('tavern-regex-test-none'),
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
              child: Text(l10n.tavernRegexTestNone, style: note),
            )
          else if (result.replacements > 0)
            SettingsSection(
              title: l10n.tavernRegexTestResult(result.replacements),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    result.text,
                    key: const ValueKey('tavern-regex-test-output'),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }
}
