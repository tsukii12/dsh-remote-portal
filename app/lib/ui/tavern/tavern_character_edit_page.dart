// 编辑角色 (docs/design/roleplay-ui.md §9): the card's text in groups. Only
// what changed is saved (Tavern.updateCharacterFields); everything else on the
// card (lorebook, extensions, pictures, fields this page does not show) stays
// exactly as it was, and existing chats keep their text.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The strings the page edits, as the card names them.
const _texts = [
  'name',
  'nickname',
  'creator',
  'character_version',
  'description',
  'personality',
  'scenario',
  'first_mes',
  'mes_example',
  'system_prompt',
  'post_history_instructions',
  'creator_notes',
];

/// Card fields that are bookkeeping, not content: not counted as kept.
const _bookkeeping = {'creation_date', 'modification_date'};

/// Splits 标签 on commas (half or full width) and 、; blanks and repeats drop.
@visibleForTesting
List<String> parseTavernTags(String text) {
  final seen = <String>{};
  return [
    for (final tag in text.split(RegExp('[,，、]')).map((t) => t.trim()))
      if (tag.isNotEmpty && seen.add(tag)) tag,
  ];
}

List<String> _strings(Object? value) => [
  if (value is List)
    for (final v in value)
      if (v is String) v,
];

bool _hasContent(Object? value) => switch (value) {
  null => false,
  String s => s.isNotEmpty,
  List l => l.isNotEmpty,
  Map m => m.isNotEmpty,
  _ => true,
};

class TavernCharacterEditPage extends ConsumerStatefulWidget {
  const TavernCharacterEditPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernCharacterEditPage(characterId: characterId));

  @override
  ConsumerState<TavernCharacterEditPage> createState() => _TavernCharacterEditPageState();
}

class _TavernCharacterEditPageState extends ConsumerState<TavernCharacterEditPage> {
  final _fields = {for (final k in _texts) k: TextEditingController()};
  final _tags = TextEditingController();
  final _greetings = <TextEditingController>[];

  /// Bumped by every edit, so the discard guard re-asks [_dirty].
  final _edits = ValueNotifier(0);

  /// The card as it was opened (null while loading); after a save, as saved.
  Map<String, Object?>? _original;
  bool _missing = false;
  bool _more = false;
  bool _saving = false;
  String? _nameError;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [..._fields.values, _tags]) {
      c.addListener(_edited);
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    final data = await ref.read(tavernProvider).characterFields(widget.characterId);
    if (!mounted) return;
    if (data == null) return setState(() => _missing = true);
    for (final k in _texts) {
      _fields[k]!.text = data[k] is String ? data[k]! as String : '';
    }
    _tags.text = _strings(data['tags']).join(_tagJoin);
    for (final g in _strings(data['alternate_greetings'])) {
      _addGreeting(g);
    }
    // The examples and prompt overrides fold away unless the card uses them.
    _more = ['mes_example', 'system_prompt', 'post_history_instructions'].any((k) => _hasContent(data[k]));
    setState(() => _original = data);
  }

  String get _tagJoin => Localizations.localeOf(context).languageCode == 'zh' ? '，' : ', ';

  void _edited() {
    _edits.value++;
    if (_nameError != null && _fields['name']!.text.trim().isNotEmpty) setState(() => _nameError = null);
  }

  void _addGreeting([String text = '']) {
    final c = TextEditingController(text: text)..addListener(_edited);
    _greetings.add(c);
  }

  void _removeGreeting(int i) {
    final c = _greetings[i];
    setState(() => _greetings.removeAt(i));
    // Its field lets go of it in this rebuild; dispose after that.
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    _edited();
  }

  @override
  void dispose() {
    for (final c in [..._fields.values, _tags, ..._greetings]) {
      c.dispose();
    }
    _edits.dispose();
    super.dispose();
  }

  /// Only the fields that differ from [_original]. Blank extra greetings are
  /// dropped; tags compare as a list, so spacing around commas is no change.
  Map<String, Object?> _patch() {
    final original = _original;
    if (original == null) return const {};
    final patch = <String, Object?>{
      for (final k in _texts)
        if (_fields[k]!.text != (original[k] is String ? original[k]! as String : '')) k: _fields[k]!.text,
    };
    final tags = parseTavernTags(_tags.text);
    if (!listEquals(tags, _strings(original['tags']))) patch['tags'] = tags;
    final greetings = [
      for (final c in _greetings)
        if (c.text.trim().isNotEmpty) c.text,
    ];
    if (!listEquals(greetings, _strings(original['alternate_greetings']))) patch['alternate_greetings'] = greetings;
    return patch;
  }

  bool _dirty() => !_saving && _patch().isNotEmpty;

  Future<void> _save() async {
    if (_saving) return;
    final l10n = context.l10n;
    if (_fields['name']!.text.trim().isEmpty) {
      setState(() => _nameError = l10n.tavernNameNeeded);
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final patch = _patch();
    if (patch.isEmpty) {
      navigator.pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(tavernProvider).updateCharacterFields(widget.characterId, patch);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is TavernImportError ? l10n.tavernCharacterGone : l10n.commonSaveFailedRetry;
        });
      }
      return;
    }
    if (!mounted) return;
    // Still 「saving」 until the page is gone, so leaving does not ask.
    messenger.showSnackBar(SnackBar(content: Text(l10n.commonSaved)));
    navigator.pop();
  }

  /// How much of the card this page leaves alone, for the note at the end.
  int _kept(Map<String, Object?> data) {
    var n = 0;
    for (final MapEntry(:key, :value) in data.entries) {
      if (_texts.contains(key) || key == 'tags' || key == 'alternate_greetings' || _bookkeeping.contains(key)) {
        continue;
      }
      if (key == 'extensions' && value is Map) {
        n += value.values.where(_hasContent).length;
      } else if (_hasContent(value)) {
        n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final original = _original;
    if (_missing) {
      return AppPage.list(
        title: l10n.tavernEditCharacter,
        children: [EmptyView(icon: AppIcons.tavern, title: l10n.tavernCharacterGone)],
      );
    }
    if (original == null) {
      return AppPage.list(title: l10n.tavernEditCharacter, children: const [QuietSpinner()]);
    }
    final enabled = !_saving;
    final kept = _kept(original);

    Widget field(
      String key,
      String label, {
      String? hint,
      String? helper,
      int minLines = 1,
      int maxLines = 1,
      String? error,
    }) => FormFieldBlock(
      key: ValueKey('tavern-field-$key'),
      label: label,
      helper: helper,
      error: error,
      child: TextField(
        controller: _fields[key],
        enabled: enabled,
        minLines: minLines,
        maxLines: maxLines,
        keyboardType: maxLines > 1 ? TextInputType.multiline : TextInputType.text,
        textInputAction: maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        decoration: InputDecoration(hintText: hint, error: error == null ? null : const SizedBox.shrink()),
      ),
    );

    final body = <Widget>[
      SettingsSection(
        title: l10n.tavernFieldsBasics,
        children: [
          FormFieldGroup(
            children: [
              field('name', l10n.tavernFieldName, error: _nameError),
              field('nickname', l10n.tavernFieldNickname, helper: l10n.tavernFieldNicknameHelp),
              FormFieldBlock(
                key: const ValueKey('tavern-field-tags'),
                label: l10n.tavernFieldTags,
                helper: l10n.tavernFieldTagsHelp,
                child: TextField(controller: _tags, enabled: enabled, textInputAction: TextInputAction.next),
              ),
              field('creator', l10n.tavernFieldCreator),
              field('character_version', l10n.tavernFieldVersion),
            ],
          ),
        ],
      ),
      SettingsSection(
        title: l10n.tavernDefinition,
        children: [
          FormFieldGroup(
            children: [
              field('description', l10n.tavernFieldDescription, minLines: 4, maxLines: 14),
              field('personality', l10n.tavernFieldPersonality, minLines: 2, maxLines: 8),
              field('scenario', l10n.tavernFieldScenario, minLines: 2, maxLines: 8),
            ],
          ),
        ],
      ),
      SettingsSection(
        title: l10n.tavernGreeting,
        footer: Text(l10n.tavernFieldGreetingsNote),
        children: [
          FormFieldGroup(
            children: [
              field('first_mes', l10n.tavernGreetingNumber(1), minLines: 3, maxLines: 12),
              for (final (i, c) in _greetings.indexed)
                FormFieldBlock(
                  key: ObjectKey(c),
                  label: l10n.tavernGreetingNumber(i + 2),
                  trailing: FormSmallButton(
                    label: l10n.commonDelete,
                    onPressed: enabled ? () => _removeGreeting(i) : null,
                  ),
                  child: TextField(
                    controller: c,
                    enabled: enabled,
                    minLines: 3,
                    maxLines: 12,
                    keyboardType: TextInputType.multiline,
                  ),
                ),
            ],
          ),
          SettingsTile(
            key: const ValueKey('tavern-add-greeting'),
            icon: AppIcons.add,
            tinted: false,
            title: l10n.tavernAddGreeting,
            onTap: enabled
                ? () {
                    setState(_addGreeting);
                    _edited();
                  }
                : null,
            chevron: false,
          ),
        ],
      ),
      SettingsSection(
        children: [
          SettingsTile(
            key: const ValueKey('tavern-more-fields'),
            title: l10n.tavernMoreFields,
            subtitle: l10n.tavernMoreFieldsSubtitle,
            trailing: AnimatedRotation(
              turns: _more ? 0.5 : 0,
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              child: Icon(AppIcons.expand, size: 18, color: DshColors.of(context).textTertiary),
            ),
            onTap: () => setState(() => _more = !_more),
          ),
        ],
      ),
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: !_more
            ? const SizedBox(width: double.infinity)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsSection(
                    children: [
                      FormFieldGroup(
                        children: [
                          field(
                            'mes_example',
                            l10n.tavernFieldExamples,
                            helper: l10n.tavernFieldExamplesHelp,
                            minLines: 3,
                            maxLines: 14,
                          ),
                        ],
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: l10n.tavernFieldPrompts,
                    footer: Text(l10n.tavernFieldPromptsNote),
                    children: [
                      FormFieldGroup(
                        children: [
                          field('system_prompt', l10n.tavernFieldSystemPrompt, minLines: 2, maxLines: 10),
                          field('post_history_instructions', l10n.tavernFieldPostHistory, minLines: 2, maxLines: 10),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
      ),
      SettingsSection(
        footer: Text(l10n.tavernFieldNotesNote),
        children: [
          FormFieldGroup(children: [field('creator_notes', l10n.tavernCreatorNotes, minLines: 2, maxLines: 10)]),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Text(
          kept > 0 ? l10n.tavernEditKeeps(kept) : l10n.tavernEditKeepsChats,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
        ),
      ),
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: _error == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
                ),
              ),
      ),
      const SizedBox(height: FormBottomBar.height),
    ];

    return DiscardGuard(
      listenable: _edits,
      isDirty: _dirty,
      child: Stack(
        children: [
          AppPage.list(
            title: l10n.tavernEditCharacter,
            children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-edit-save'),
                onPressed: enabled ? _save : null,
                child: Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
