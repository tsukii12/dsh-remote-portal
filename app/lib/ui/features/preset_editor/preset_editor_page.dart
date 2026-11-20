// 新建 / 复制 / 编辑 Agent 预设 (a form page): name, id, description, the
// preset it starts from, the system prompt (the persona's `prefix`, optionally
// the whole prompt) and every row of its plugin list as a switch, named with
// the official package names.
//
// The Host has no Remote that writes a preset (`dsh-agent-preset-registry`:
// "没有任何接口接受 YAML 写回"); the official page hands creation to creator
// mode. Saving here does the same, with the exact bundle (package.json +
// cordis.patch.yml) to write and install, then opens that conversation.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/connection_state.dart';
import '../../../state/features_state.dart';
import '../../../state/hosts_state.dart';
import '../../../state/preset_editor_state.dart';
import '../../../state/read_list_identity.dart';
import '../../common/discard_guard.dart';
import '../../common/smooth_size.dart';
import '../../providers/provider_widgets.dart';
import '../../settings/settings_widgets.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../feature_format.dart';
import '../feature_widgets.dart';
import '../schedule_editor/schedule_pickers.dart';
import 'preset_composition.dart';

enum PresetEditMode { create, duplicate, edit }

class PresetEditorPage extends ConsumerStatefulWidget {
  const PresetEditorPage({super.key, this.mode = PresetEditMode.create, this.source, this.bundle});

  final PresetEditMode mode;

  /// Duplicate: the preset copied; edit: the preset changed. Null for a new
  /// preset (it starts from the standard one).
  final AgentPresetInfo? source;

  /// Edit: the bundle that declares [source] now.
  final PluginBundle? bundle;

  @override
  ConsumerState<PresetEditorPage> createState() => _PresetEditorPageState();
}

enum _F { name, id }

class _PresetEditorPageState extends ConsumerState<PresetEditorPage> {
  late final _name = TextEditingController(
    text: switch (widget.mode) {
      PresetEditMode.create => '',
      PresetEditMode.duplicate => appL10n.featuresPresetCopyName(_sourceName ?? ''),
      PresetEditMode.edit => _sourceName ?? '',
    },
  );
  late final _id = TextEditingController(text: widget.mode == PresetEditMode.edit ? widget.source!.id : '');
  late final _description = TextEditingController(
    text: widget.mode == PresetEditMode.create || widget.source == null ? '' : agentPresetDescription(widget.source!),
  );
  final _prompt = TextEditingController();
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  /// The id field follows the name until it is typed into.
  bool _idTouched = false;

  late String _base = widget.source?.id ?? 'standard';

  /// The composition loaded for [_base], and the switches over it.
  PresetComposition? _composition;
  String? _loadedBase;
  Set<String> _enabled = const {};
  bool _complete = false;

  Object? _saveAttempt;
  bool get _saving => _saveAttempt != null;
  Map<_F, String> _errors = const {};
  String? _formError;

  String? get _sourceName => widget.source == null ? null : agentPresetName(widget.source!);

  bool get _isEdit => widget.mode == PresetEditMode.edit;

  /// The form as opened, to tell an edit from the page as it loaded.
  late String _clean;
  late final Listenable _edits = Listenable.merge([_name, _id, _description, _prompt]);

  String _signature() =>
      jsonEncode([_name.text, _id.text, _description.text, _prompt.text, _base, _enabled.toList()..sort(), _complete]);

  @override
  void initState() {
    super.initState();
    _clean = _signature();
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    _description.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _load(PresetComposition composition) {
    _composition = composition;
    _loadedBase = _base;
    _enabled = composition.enabled;
    _complete = composition.completePrompt;
    _prompt.text = composition.prompt;
  }

  /// A free id for a copy: `<id>-copy`, `<id>-copy-2`, …
  String _freeId(String stem, Set<String> taken) {
    if (!taken.contains(stem)) return stem;
    for (var n = 2; ; n++) {
      if (!taken.contains('$stem-$n')) return '$stem-$n';
    }
  }

  void _nameChanged(String name, Set<String> taken) {
    if (!_idTouched && !_isEdit) {
      final slug = presetIdFromName(name);
      _id.text = slug == null ? '' : _freeId(slug, taken);
    }
    if (_errors.isNotEmpty || _formError != null) {
      setState(() {
        _errors = {};
        _formError = null;
      });
    }
  }

  Future<void> _pickBase(List<AgentPresetInfo> presets) async {
    final picked = await showChoiceSheet<String>(
      context,
      title: context.l10n.featuresPresetBasedOn,
      selected: _base,
      choices: [
        for (final p in presets)
          if (p.broken == null) Choice(p.id, agentPresetName(p), subtitle: agentPresetDescription(p)),
      ],
    );
    if (picked == null || picked == _base || !mounted) return;
    setState(() => _base = picked);
  }

  Future<void> _save(List<AgentPresetInfo> presets) async {
    if (_saving) return;
    final composition = _composition;
    if (composition == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final taken = {for (final p in presets) p.id};
    final name = _name.text.trim();
    final id = _id.text.trim();
    final errors = <_F, String>{
      if (name.isEmpty) _F.name: context.l10n.featuresNameRequired,
      if (!_isEdit) _F.id: ?presetIdError(id, taken),
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final target = _fieldKeys[_F.values.firstWhere(errors.containsKey)]!.currentContext;
      if (target != null) unawaited(Scrollable.ensureVisible(target, alignment: 0.3));
      return;
    }
    final orders = [for (final p in presets) ?p.order];
    final bundle = PresetBundle(
      id: id,
      name: name,
      description: _description.text.trim(),
      order: _isEdit ? widget.source?.order : (orders.isEmpty ? 10 : orders.reduce((a, b) => a > b ? a : b) + 1),
      packageName: _isEdit ? widget.bundle?.name : null,
      plugins: composition.render(
        enabled: _enabled,
        prompt: composition.hasPersona && _prompt.text != composition.prompt ? _prompt.text.trim() : null,
        complete: composition.hasPersona ? _complete : null,
      ),
    );
    final connection = ref.read(readListLiveConnectionProvider);
    if (connection == null) return;
    final selected = ref.read(activeHostProvider);
    final client = connection.client;
    final generation = client.mux.generation;
    final ready = client.mux.lastReadyGenerationNumber;
    final route = ModalRoute.of(context);
    final attempt = Object();
    var retired = false;
    final selection = ref.listenManual(activeHostProvider, (_, next) {
      if (next != selected) retired = true;
    });
    final connectionChanges = ref.listenManual(activeConnectionProvider, (_, next) {
      if (!identical(readListConnection(next, selected)?.client, client)) retired = true;
    });
    final muxChanges = client.mux.states.listen((state) {
      if (state == DshConnectionState.reconnecting ||
          state == DshConnectionState.unauthorized ||
          state == DshConnectionState.closed) {
        retired = true;
      }
    });
    bool ownsSave() {
      if (!mounted || retired || !identical(_saveAttempt, attempt) || (route != null && !route.isCurrent)) return false;
      if (!identical(ref.read(readListLiveConnectionProvider)?.client, client)) return false;
      final state = client.mux.state;
      if (state == DshConnectionState.reconnecting ||
          state == DshConnectionState.unauthorized ||
          state == DshConnectionState.closed) {
        return false;
      }
      final current = client.mux.generation;
      // Local HTTP can already work while its first mux ready is pending.
      // That first ready is not a reconnect; later generations retire this save.
      return (identical(current, generation) && client.mux.lastReadyGenerationNumber == ready) ||
          (generation == null && ready == 0 && current != null && client.mux.lastReadyGenerationNumber == 1);
    }

    setState(() => _saveAttempt = attempt);
    try {
      final session = await startCreator(
        ref,
        bundle.request(replacing: _isEdit ? widget.bundle?.name : null),
        isCurrent: ownsSave,
      );
      if (mounted && ownsSave()) openSessionInChat(context, ref, session);
    } on Object {
      if (ownsSave()) setState(() => _formError = context.l10n.featuresCreatorOpenFailed);
    } finally {
      selection.close();
      connectionChanges.close();
      unawaited(muxChanges.cancel());
      // Publication may have retired while this attempt still owns its spinner.
      if (mounted && identical(_saveAttempt, attempt)) setState(() => _saveAttempt = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final connected = ref.watch(readListLiveConnectionProvider) != null;
    final presets = ref.watch(agentPresetsProvider).value ?? const <AgentPresetInfo>[];
    final taken = {for (final p in presets) p.id};
    final doc = ref.watch(agentPresetDocumentProvider(_base));
    if (doc case AsyncData(:final value) when _loadedBase != _base) {
      final firstLoad = _loadedBase == null;
      _load(PresetComposition.parse(value.content));
      if (widget.mode == PresetEditMode.duplicate && !_idTouched && _id.text.isEmpty) {
        _id.text = _freeId('${widget.source!.id}-copy', taken);
      }
      // What the first load fills in is the page as opened, not an edit.
      if (firstLoad) _clean = _signature();
    }
    final composition = _loadedBase == _base ? _composition : null;
    final creator = creatorAvailable(ref.watch(agentPresetsProvider).value);
    final enabled = !_saving;

    final List<Widget> body = [
      SettingsSection(
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                key: _fieldKeys[_F.name],
                error: _errors[_F.name],
                label: l10n.commonName,
                child: TextField(
                  controller: _name,
                  enabled: enabled,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [LengthLimitingTextInputFormatter(40)],
                  onChanged: (v) => _nameChanged(v, taken),
                  decoration: InputDecoration(
                    hintText: l10n.featuresPresetNameHint,
                    error: _errors[_F.name] == null ? null : const SizedBox.shrink(),
                  ),
                ),
              ),
              FormFieldBlock(
                key: _fieldKeys[_F.id],
                error: _errors[_F.id],
                label: l10n.featuresPresetId,
                helper: _isEdit || _errors[_F.id] != null ? null : l10n.featuresPresetIdHint,
                child: TextField(
                  controller: _id,
                  enabled: enabled && !_isEdit,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  style: AppType.mono(size: 15, color: scheme.onSurface),
                  inputFormatters: [LengthLimitingTextInputFormatter(40)],
                  onChanged: (_) {
                    _idTouched = true;
                    if (_errors.containsKey(_F.id)) setState(() => _errors = {..._errors}..remove(_F.id));
                  },
                  decoration: InputDecoration(
                    hintText: 'my-preset',
                    error: _errors[_F.id] == null ? null : const SizedBox.shrink(),
                  ),
                ),
              ),
              FormFieldBlock(
                label: l10n.featuresPresetDescription,
                child: TextField(
                  controller: _description,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 3,
                  inputFormatters: [LengthLimitingTextInputFormatter(120)],
                  decoration: InputDecoration(hintText: l10n.featuresPresetDescriptionHint),
                ),
              ),
            ],
          ),
          if (widget.mode == PresetEditMode.create)
            SettingsTile(
              title: l10n.featuresPresetBasedOn,
              value: Text(presetLabel(_base, presets)),
              onTap: enabled ? () => _pickBase(presets) : null,
            ),
        ],
      ),
      if (doc.hasError && composition == null)
        FeatureMessage(
          icon: AppIcons.error,
          title: l10n.featuresPresetConfigReadFailed,
          action: (l10n.commonRetry, () => ref.invalidate(agentPresetDocumentProvider(_base))),
        )
      else if (composition == null)
        const FeatureLoading()
      else
        ..._compositionSections(composition, enabled),
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: _formError == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(_formError!, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
      ),
      const SizedBox(height: FormBottomBar.height),
    ];

    final page = AppPage.list(
      title: switch (widget.mode) {
        PresetEditMode.create => l10n.featuresPresetCreateTitle,
        PresetEditMode.duplicate => l10n.featuresPresetDuplicateTitle,
        PresetEditMode.edit => l10n.featuresPresetEditTitle,
      },
      children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
    );
    final ready = connected && creator && composition != null && !_saving;
    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: ready ? () => _save(presets) : null,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(l10n.featuresCreatorOpening),
                        ],
                      )
                    : Text(
                        !connected
                            ? l10n.featuresWaitingEngine
                            : !creator
                            ? l10n.featuresCreatorUnavailable
                            : _isEdit
                            ? l10n.featuresPresetStartUpdate
                            : l10n.featuresPresetStartCreate,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _compositionSections(PresetComposition composition, bool enabled) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    Widget switches(String title, PresetRowKind kind) {
      final rows = [
        for (final r in composition.switchable)
          if (r.kind == kind) r,
      ];
      if (rows.isEmpty) return const SizedBox.shrink();
      final on = rows.where((r) => _enabled.contains(r.id)).length;
      return SettingsSection(
        title: '$title · $on/${rows.length}',
        children: [
          for (final r in rows)
            SettingsSwitchTile(
              tinted: false,
              title: r.label,
              value: _enabled.contains(r.id),
              onChanged: enabled
                  ? (v) => setState(() => _enabled = v ? {..._enabled, r.id} : ({..._enabled}..remove(r.id)))
                  : null,
            ),
        ],
      );
    }

    return [
      if (composition.hasPersona)
        SettingsSection(
          title: context.l10n.featuresPresetSystemPrompt,
          children: [
            FormFieldGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: _prompt,
                    enabled: enabled,
                    minLines: 6,
                    maxLines: 16,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                    decoration: InputDecoration(
                      hintText: context.l10n.featuresPresetSystemPromptHint,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary, height: 1.55),
                    ),
                  ),
                ),
              ],
            ),
            SettingsSwitchTile(
              tinted: false,
              title: context.l10n.featuresPresetReplaceSystemPrompt,
              value: _complete,
              onChanged: enabled ? (v) => setState(() => _complete = v) : null,
            ),
          ],
        ),
      switches(context.l10n.featuresPresetTools, PresetRowKind.tool),
      switches(context.l10n.featuresSkills, PresetRowKind.skill),
      switches(context.l10n.featuresPresetContextModes, PresetRowKind.context),
    ];
  }
}

/// The name a preset id shows under.
String presetLabel(String id, List<AgentPresetInfo> presets) {
  final preset = presets.where((p) => p.id == id).firstOrNull;
  return preset == null ? id : agentPresetName(preset);
}
