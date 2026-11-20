// 对话 › 新建群聊 (engine P2 125, roleplay-agent.md §4): pick who is in it,
// in the order they first speak; a name if you like (theirs, joined, if
// not); and how they take turns. The first picked hosts it: their card holds
// the story's shared state.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_page.dart';

/// How a group takes turns, as the reader picks it; 导演 is the director's
/// call, chosen from the group's own settings once it has one.
String tavernGroupActivationName(BuildContext context, TavernGroupActivation activation) {
  final l10n = context.l10n;
  return switch (activation) {
    TavernGroupActivation.natural => l10n.tavernGroupNatural,
    TavernGroupActivation.listOrder => l10n.tavernGroupListOrder,
    TavernGroupActivation.randomPool => l10n.tavernGroupRandom,
    TavernGroupActivation.manual => l10n.tavernGroupManual,
    TavernGroupActivation.director => l10n.tavernGroupDirector,
  };
}

/// What each way of taking turns does, in a line.
String tavernGroupActivationNote(BuildContext context, TavernGroupActivation activation) {
  final l10n = context.l10n;
  return switch (activation) {
    TavernGroupActivation.natural => l10n.tavernGroupNaturalNote,
    TavernGroupActivation.listOrder => l10n.tavernGroupListOrderNote,
    TavernGroupActivation.randomPool => l10n.tavernGroupRandomNote,
    TavernGroupActivation.manual => l10n.tavernGroupManualNote,
    TavernGroupActivation.director => l10n.tavernGroupDirectorNote,
  };
}

class TavernGroupNewPage extends ConsumerStatefulWidget {
  const TavernGroupNewPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernGroupNewPage());

  @override
  ConsumerState<TavernGroupNewPage> createState() => _TavernGroupNewPageState();
}

class _TavernGroupNewPageState extends ConsumerState<TavernGroupNewPage> {
  final _title = TextEditingController();

  /// Picked, in the order picked: who speaks first, and who hosts.
  final _picked = <String>[];
  TavernGroupActivation _activation = TavernGroupActivation.natural;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _toggle(String id) => setState(() {
    if (!_picked.remove(id)) _picked.add(id);
  });

  Future<void> _create() async {
    if (_creating || _picked.length < 2) return;
    final navigator = Navigator.of(context);
    final l10n = context.l10n;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final title = _title.text.trim();
      final chatId = await ref
          .read(tavernProvider)
          .createGroupChat(List.of(_picked), title: title.isEmpty ? null : title, activation: _activation);
      if (!mounted) return;
      unawaited(navigator.pushReplacement(TavernChatPage.route(chatId)));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = l10n.tavernGroupCreateFailed('$e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final characters = ref.watch(tavernCharactersProvider).value;
    return Stack(
      children: [
        AppPage.list(
          title: l10n.tavernGroupNew,
          children: [
            if (characters == null)
              const QuietSpinner()
            else ...[
              SettingsSection(
                title: l10n.tavernGroupMembers,
                footer: Text(l10n.tavernGroupMembersNote),
                children: [
                  for (final c in characters)
                    SettingsTile(
                      key: ValueKey('tavern-group-pick-${c.id}'),
                      tinted: false,
                      title: c.name,
                      value: switch (_picked.indexOf(c.id)) {
                        -1 => null,
                        0 => Text(l10n.tavernGroupHost),
                        final n => Text('${n + 1}'),
                      },
                      trailing: Icon(
                        _picked.contains(c.id) ? AppIcons.checkboxOn : AppIcons.checkboxOff,
                        color: _picked.contains(c.id) ? theme.colorScheme.primary : dsh.textTertiary,
                      ),
                      chevron: false,
                      onTap: _creating ? null : () => _toggle(c.id),
                    ),
                ],
              ),
              SettingsSection(
                children: [
                  FormFieldGroup(
                    children: [
                      FormFieldBlock(
                        label: l10n.tavernGroupTitle,
                        child: TextField(
                          key: const ValueKey('tavern-group-title'),
                          controller: _title,
                          enabled: !_creating,
                          decoration: InputDecoration(
                            hintText: [
                              for (final id in _picked)
                                if (characters.where((c) => c.id == id).firstOrNull case final c?) c.name,
                            ].join('、'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              SettingsSection(
                footer: Text(tavernGroupActivationNote(context, _activation)),
                children: [
                  SettingsSegmentTile<TavernGroupActivation>(
                    key: const ValueKey('tavern-group-activation'),
                    title: l10n.tavernGroupActivation,
                    segments: [
                      for (final a in const [
                        TavernGroupActivation.natural,
                        TavernGroupActivation.listOrder,
                        TavernGroupActivation.randomPool,
                        TavernGroupActivation.manual,
                      ])
                        PillSegment(a, tavernGroupActivationName(context, a)),
                    ],
                    selected: _activation,
                    onChanged: (a) => setState(() => _activation = a),
                  ),
                ],
              ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
                ),
              const SizedBox(height: FormBottomBar.height),
            ],
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: FormBottomBar(
            child: FilledButton(
              key: const ValueKey('tavern-group-create'),
              onPressed: _creating || _picked.length < 2 ? null : () => unawaited(_create()),
              child: Text(_picked.length < 2 ? l10n.tavernGroupPickTwo : l10n.tavernGroupCreate(_picked.length)),
            ),
          ),
        ),
      ],
    );
  }
}
