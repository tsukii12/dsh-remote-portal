// 新建 Bot: a name, a role, how it works, a
// color and a model; 「创建」 stays above the keyboard.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../chat/model_sheet.dart';
import '../common/discard_guard.dart';
import '../common/list_page_row.dart';
import '../providers/provider_widgets.dart' show FormBottomBar, FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart' show SettingsSection;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'bot_avatar.dart';
import 'bot_chat_page.dart';
import 'bot_details_page.dart' show BotColorPicker, effortName, shortModel;
import 'bot_format.dart';
import 'bot_creation_scope.dart';

class NewBotPage extends ConsumerStatefulWidget {
  const NewBotPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const NewBotPage());

  @override
  ConsumerState<NewBotPage> createState() => _NewBotPageState();
}

class _NewBotPageState extends ConsumerState<NewBotPage> {
  final _name = TextEditingController();
  final _role = TextEditingController();
  final _instructions = TextEditingController();
  String _color = dsBotPickerColors[5];
  ModelSelection? _model;
  bool _saving = false;
  BotCreationScope? _scope;
  String? _nameError;

  late final Listenable _edits = Listenable.merge([_name, _role, _instructions]);
  late String _clean;

  String _signature() => jsonEncode([
    _name.text,
    _role.text,
    _instructions.text,
    _color,
    _model?.provider,
    _model?.model,
    _model?.reasoningEffort,
  ]);

  @override
  void initState() {
    super.initState();
    _clean = _signature();
  }

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _instructions.dispose();
    super.dispose();
  }

  /// The model it starts on: picked here, else the host's default.
  ModelSelection? _effectiveModel(DsBotTeam? team) {
    if (_model != null) return _model;
    final ref = team?.defaultModel;
    final slash = ref?.indexOf('/') ?? -1;
    if (ref == null || slash <= 0) return null;
    return ModelSelection(provider: ref.substring(0, slash), model: ref.substring(slash + 1));
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = appL10n.botsNameRequired);
      return;
    }
    final scope = _scope;
    if (_saving || scope == null || !scope.writable(ref)) return;
    final hub = ref.read(dsBotProvider.notifier);
    final api = scope.api;
    final model = _effectiveModel(ref.read(dsBotProvider).team);
    setState(() {
      _saving = true;
      _nameError = null;
    });
    try {
      final bot = await api.createBot(
        name: name,
        role: _role.text.trim().isEmpty ? null : _role.text.trim(),
        instructions: _instructions.text.trim().isEmpty ? null : _instructions.text.trim(),
        color: _color,
        model: model == null ? null : '${model.provider}/${model.model}',
        effort: model?.reasoningEffort,
      );
      if (!mounted || !scope.connected(ref)) return;
      await hub.refresh();
      if (!mounted || !scope.connected(ref)) return;
      await Navigator.of(context).pushReplacement(BotChatPage.route(bot.id));
    } catch (error) {
      if (!mounted || !scope.connected(ref)) return;
      setState(() {
        _saving = false;
        _nameError = describeDsBotError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    _scope ??= BotCreationScope.capture(ref);
    final changed = _scope != null && !_scope!.connected(ref);
    final saving = _saving && !changed;
    final model = _effectiveModel(status.team);
    final name = _name.text.trim();
    final scheme = Theme.of(context).colorScheme;
    final page = AppPage.list(
      title: l10n.botsNewBot,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: name.isEmpty ? _Placeholder(color: _color) : BotMonogram(name: name, color: _color, size: 64),
              ),
            ),
            SettingsSection(
              title: l10n.botsProfile,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.botsBotName,
                      error: _nameError,
                      child: TextField(
                        key: const ValueKey('bot-name'),
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [LengthLimitingTextInputFormatter(40)],
                        onChanged: (_) => setState(() => _nameError = null),
                        decoration: InputDecoration(
                          hintText: l10n.botsWriterExample,
                          error: _nameError == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.botsRole,
                      child: TextField(
                        key: const ValueKey('bot-role'),
                        controller: _role,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [LengthLimitingTextInputFormatter(24)],
                        decoration: InputDecoration(hintText: l10n.botsRoleHint),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.botsInstructions,
                      child: TextField(
                        key: const ValueKey('bot-instructions'),
                        controller: _instructions,
                        minLines: 3,
                        maxLines: 8,
                        decoration: InputDecoration(hintText: l10n.botsNewInstructionsHint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.botsAppearance,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: BotColorPicker(selected: _color, onPick: (color) => setState(() => _color = color)),
                ),
              ],
            ),
            SettingsSection(
              title: l10n.botsModel,
              children: [
                ListPageRow(
                  icon: AppIcons.model,
                  title: l10n.botsModel,
                  value: model == null
                      ? l10n.botsChooseModel
                      : [
                          shortModel(modelLabel('${model.provider}/${model.model}', status.team?.models ?? const [])),
                          if (model.reasoningEffort case final e?) effortName(e),
                        ].join(' · '),
                  onTap: () => showModelSheet(
                    context,
                    current: model,
                    onSelected: (selection) => setState(() => _model = selection),
                  ),
                ),
              ],
            ),
            if (changed) Text(l10n.botsCreationConnectionChanged, style: TextStyle(color: scheme.error)),
            const SizedBox(height: FormBottomBar.height),
          ],
        ),
      ],
    );
    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('bot-create'),
                onPressed: saving || _scope == null || !_scope!.writable(ref) ? null : _create,
                child: saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(l10n.botsCreating),
                        ],
                      )
                    : Text(l10n.commonCreate),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The avatar before the Bot has a name: its color behind a quiet glyph.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.color});

  final String color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: 64,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: botInk(context, color).withValues(alpha: dark ? 0.26 : 0.16),
          shape: const CircleBorder(),
        ),
        child: Icon(AppIcons.bot, size: 28, color: botNameInk(context, color)),
      ),
    );
  }
}
