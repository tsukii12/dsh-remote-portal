// 酒馆设置 › 渠道: which endpoint the tavern talks to. DeepSeek's own is
// built in (the app's key); the person adds any OpenAI-compatible one with
// its Base URL, key and model, the model typed or picked from its /models.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/provider_keys.dart';
import '../../state/providers_state.dart';
import '../../tavern/tavern_channels.dart';
import '../../tavern/tavern_settings.dart';
import '../bots/bot_sheets.dart' show confirmDelete;
import '../common/app_sheet.dart';
import '../common/discard_guard.dart';
import '../common/sheet_title_bar.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class TavernChannelsPage extends ConsumerWidget {
  const TavernChannelsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernChannelsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(tavernSettingsProvider);
    final controller = ref.read(tavernSettingsProvider.notifier);
    final active = settings.activeChannel;
    Widget row({
      required String id,
      required String title,
      required String subtitle,
      required bool checked,
      required VoidCallback onTap,
      VoidCallback? onEdit,
    }) => SettingsTile(
      key: ValueKey('tavern-channel-$id'),
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              key: ValueKey('tavern-channel-$id-edit'),
              tooltip: l10n.tavernChannelEdit,
              icon: const Icon(AppIcons.edit, size: 20),
              onPressed: onEdit,
            ),
          SelectionTick(checked: checked),
        ],
      ),
      onTap: onTap,
    );
    return AppPage.list(
      title: l10n.tavernChannel,
      children: [
        SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            row(
              id: 'deepseek',
              title: l10n.tavernChannelDeepSeek,
              subtitle: l10n.tavernChannelDeepSeekNote,
              checked: active == null,
              onTap: () => unawaited(controller.setChannel(null)),
            ),
            for (final channel in settings.channels)
              row(
                id: channel.id,
                title: channel.name,
                subtitle: '${channel.host} · ${channel.model}',
                checked: active?.id == channel.id,
                onTap: () => unawaited(controller.setChannel(channel.id)),
                onEdit: () => unawaited(Navigator.of(context).push(TavernChannelEditPage.route(channel))),
              ),
            SettingsTile(
              key: const ValueKey('tavern-channel-add'),
              icon: AppIcons.add,
              title: l10n.tavernChannelAdd,
              onTap: () => unawaited(Navigator.of(context).push(TavernChannelEditPage.route(null))),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          child: Text(
            l10n.tavernChannelsNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
      ],
    );
  }
}

/// Adds a channel (null) or edits one; saving a new one also starts using it.
class TavernChannelEditPage extends ConsumerStatefulWidget {
  const TavernChannelEditPage({super.key, this.channel});

  static Route<void> route(TavernChannel? channel) =>
      MaterialPageRoute<void>(builder: (_) => TavernChannelEditPage(channel: channel));

  final TavernChannel? channel;

  @override
  ConsumerState<TavernChannelEditPage> createState() => _TavernChannelEditPageState();
}

class _TavernChannelEditPageState extends ConsumerState<TavernChannelEditPage> {
  late final _name = TextEditingController(text: widget.channel?.name ?? '');
  late final _baseUrl = TextEditingController(text: widget.channel?.baseUrl ?? '');
  final _key = TextEditingController();
  late final _model = TextEditingController(text: widget.channel?.model ?? '');
  late final _headers = TextEditingController(text: tavernHeaderLines(widget.channel?.headers ?? const {}));
  late var _deepseek = widget.channel?.deepseek ?? false;
  late final _edits = Listenable.merge([_name, _baseUrl, _key, _model, _headers]);
  var _obscure = true;
  var _fetching = false;
  var _saved = false;

  /// A save under way: Save waits, so two taps make one channel.
  var _saving = false;
  String? _baseUrlError;
  String? _modelError;
  String? _headersError;
  String? _fetchNote;

  /// The stored key of the channel being edited, so the field can say so.
  bool _keyStored = false;

  /// 清除 was tapped: saving removes the stored key.
  bool _clearKey = false;

  @override
  void initState() {
    super.initState();
    if (widget.channel case final channel?) {
      unawaited(
        ref.read(tavernChannelKeysProvider).read(channel.id).then((key) {
          if (mounted) setState(() => _keyStored = key != null && key.isNotEmpty);
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _baseUrl, _key, _model, _headers]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _dirty =>
      !_saved &&
      (_name.text != (widget.channel?.name ?? '') ||
          _baseUrl.text != (widget.channel?.baseUrl ?? '') ||
          _key.text.isNotEmpty ||
          _clearKey ||
          _model.text != (widget.channel?.model ?? '') ||
          _headers.text != tavernHeaderLines(widget.channel?.headers ?? const {}) ||
          _deepseek != (widget.channel?.deepseek ?? false));

  /// The key to use for /models: the one typed, else the stored one.
  Future<String?> _currentKey() async {
    final typed = _key.text.trim();
    if (typed.isNotEmpty) return typed;
    // 清除 tapped: the channel will have none, so neither does the lookup.
    if (_clearKey) return null;
    final channel = widget.channel;
    return channel == null ? null : ref.read(tavernChannelKeysProvider).read(channel.id);
  }

  Future<void> _fetch() async {
    final l10n = context.l10n;
    if (tavernBaseUrlProblem(_baseUrl.text) != null) {
      return setState(() => _baseUrlError = l10n.tavernChannelBaseUrlInvalid);
    }
    setState(() {
      _fetching = true;
      _fetchNote = null;
    });
    try {
      final headers = tavernParseHeaders(_headers.text);
      if (headers == null) return setState(() => _headersError = l10n.tavernChannelHeadersInvalid);
      final models = await fetchTavernModels(_baseUrl.text.trim(), await _currentKey(), headers: headers);
      if (!mounted) return;
      if (models.isEmpty) return setState(() => _fetchNote = l10n.tavernChannelNoModels);
      final picked = await _pickModel(context, models, _model.text.trim());
      if (picked != null && mounted) {
        _model.text = picked;
        setState(() => _modelError = null);
      }
    } on TavernModelsException catch (e) {
      if (mounted) setState(() => _fetchNote = l10n.tavernChannelFetchFailed(e.detail));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted) return;
    if (text != null && text.isNotEmpty) _key.text = text;
  }

  /// Fills the form from one of the app's own custom providers.
  Future<void> _copyFrom(CustomProvider provider) async {
    final key = (await ref.read(providerKeyVaultProvider).readAll())[provider.id];
    if (!mounted) return;
    setState(() {
      _name.text = provider.displayName;
      _baseUrl.text = provider.baseUrl;
      if (provider.models.isNotEmpty) _model.text = provider.models.first.id;
      if (key != null) _key.text = key;
      _baseUrlError = null;
      _modelError = null;
    });
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    final headers = tavernParseHeaders(_headers.text);
    setState(() {
      _baseUrlError = tavernBaseUrlProblem(baseUrl) == null ? null : l10n.tavernChannelBaseUrlInvalid;
      _modelError = model.isEmpty ? l10n.tavernChannelModelMissing : null;
      _headersError = headers == null ? l10n.tavernChannelHeadersInvalid : null;
    });
    if (_baseUrlError != null || _modelError != null || headers == null || _saving) return;
    setState(() => _saving = true);
    final name = _name.text.trim();
    final channel = TavernChannel(
      id: widget.channel?.id ?? 'c${DateTime.now().microsecondsSinceEpoch}',
      name: name.isEmpty ? (Uri.tryParse(baseUrl)?.host ?? baseUrl) : name,
      baseUrl: baseUrl,
      model: model,
      deepseek: _deepseek,
      headers: headers,
    );
    final controller = ref.read(tavernSettingsProvider.notifier);
    final key = _key.text.trim();
    // A new channel saves whatever key was typed (none for a local server);
    // an edit keeps the stored key unless a new one was typed.
    try {
      await controller.saveChannel(channel, key: widget.channel == null || key.isNotEmpty || _clearKey ? key : null);
      if (widget.channel == null) await controller.setChannel(channel.id);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    _saved = true;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final channel = widget.channel!;
    final ok = await confirmDelete(
      context,
      title: l10n.tavernChannelDeleteTitle(channel.name),
      body: l10n.tavernChannelDeleteMessage,
    );
    if (!ok || !mounted) return;
    await ref.read(tavernSettingsProvider.notifier).deleteChannel(channel.id);
    _saved = true;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final quiet = Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary);
    // The app's own OpenAI-compatible providers, offered as a starting point
    // for a new channel.
    final appProviders = widget.channel != null
        ? const <CustomProvider>[]
        : [
            for (final p in ref.watch(customProvidersProvider).value?.providers ?? const <CustomProvider>[])
              if (p.api == ProviderApi.openaiCompletions && p.baseUrl.isNotEmpty) p,
          ];
    final page = AppPage.list(
      title: widget.channel == null ? l10n.tavernChannelAdd : l10n.tavernChannelEdit,
      children: [
        if (appProviders.isNotEmpty)
          SettingsSection(
            title: l10n.tavernChannelCopyFromApp,
            children: [
              for (final p in appProviders)
                SettingsTile(
                  key: ValueKey('tavern-channel-copy-${p.id}'),
                  icon: AppIcons.providers,
                  title: p.displayName,
                  subtitle: p.host,
                  onTap: () => unawaited(_copyFrom(p)),
                ),
            ],
          ),
        SettingsSection(
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.tavernChannelName,
                  child: TextField(
                    key: const ValueKey('tavern-channel-name'),
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [LengthLimitingTextInputFormatter(32)],
                    decoration: InputDecoration(hintText: l10n.tavernChannelNameHint),
                  ),
                ),
                FormFieldBlock(
                  label: 'Base URL',
                  error: _baseUrlError,
                  child: TextField(
                    key: const ValueKey('tavern-channel-base-url'),
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) {
                      if (_baseUrlError != null) setState(() => _baseUrlError = null);
                    },
                    decoration: InputDecoration(
                      hintText: 'https://api.example.com/v1',
                      error: _baseUrlError == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
                FormFieldBlock(
                  label: 'API Key',
                  helper: _clearKey
                      ? l10n.tavernChannelKeyCleared
                      : _keyStored
                      ? l10n.tavernChannelKeyKept
                      : l10n.tavernChannelKeyOptional,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_keyStored && !_clearKey)
                        FormSmallButton(
                          key: const ValueKey('tavern-channel-key-clear'),
                          label: l10n.tavernChannelKeyClear,
                          onPressed: () => setState(() {
                            _clearKey = true;
                            _key.clear();
                          }),
                        ),
                      FormSmallButton(label: l10n.commonPaste, onPressed: () => unawaited(_paste())),
                    ],
                  ),
                  child: TextField(
                    key: const ValueKey('tavern-channel-key'),
                    controller: _key,
                    obscureText: _obscure,
                    obscuringCharacter: '•',
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: InputDecoration(
                      hintText: _keyStored ? '••••••••' : 'sk-…',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? l10n.engineFieldShow : l10n.commonHide,
                        icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.tavernSettingsModel,
                  error: _modelError,
                  helper: _fetchNote,
                  trailing: FormSmallButton(
                    key: const ValueKey('tavern-channel-fetch'),
                    label: _fetching ? l10n.tavernChannelFetching : l10n.tavernChannelFetchModels,
                    onPressed: _fetching ? null : () => unawaited(_fetch()),
                  ),
                  child: TextField(
                    key: const ValueKey('tavern-channel-model'),
                    controller: _model,
                    autocorrect: false,
                    onChanged: (_) {
                      if (_modelError != null) setState(() => _modelError = null);
                    },
                    decoration: InputDecoration(
                      hintText: l10n.tavernChannelModelHint,
                      error: _modelError == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.tavernChannelHeaders,
                  error: _headersError,
                  helper: l10n.tavernChannelHeadersNote,
                  child: TextField(
                    key: const ValueKey('tavern-channel-headers'),
                    controller: _headers,
                    autocorrect: false,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    style: AppType.mono(size: 13),
                    onChanged: (_) {
                      if (_headersError != null) setState(() => _headersError = null);
                    },
                    decoration: InputDecoration(
                      hintText: 'HTTP-Referer: https://…',
                      error: _headersError == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          children: [
            SettingsSwitchTile(
              key: const ValueKey('tavern-channel-deepseek-api'),
              title: l10n.tavernChannelDeepSeekApi,
              subtitle: l10n.tavernChannelDeepSeekApiNote,
              value: _deepseek,
              onChanged: (on) => setState(() => _deepseek = on),
            ),
          ],
        ),
        if (widget.channel != null)
          SettingsSection(
            children: [
              SettingsTile(
                key: const ValueKey('tavern-channel-delete'),
                icon: AppIcons.delete,
                title: l10n.tavernChannelDelete,
                danger: true,
                onTap: () => unawaited(_delete()),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, FormBottomBar.height),
          child: Text(l10n.tavernChannelsNote, style: quiet),
        ),
      ],
    );
    return DiscardGuard(
      listenable: _edits,
      isDirty: () => _dirty,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-channel-save'),
                onPressed: _saving ? null : () => unawaited(_save()),
                child: Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The endpoint's models in a sheet with a search field; the one tapped.
Future<String?> _pickModel(BuildContext context, List<String> models, String current) => showAppSheet<String>(
  context,
  isScrollControlled: true,
  heightFactor: 0.8,
  builder: (_) => _ModelPicker(models: models, current: current),
);

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.current});

  final List<String> models;
  final String current;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final query = _query.toLowerCase();
    final shown = [
      for (final m in widget.models)
        if (m.toLowerCase().contains(query)) m,
    ];
    return Column(
      children: [
        SheetTitleBar(l10n.tavernChannelPickModel),
        Padding(
          padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
          child: TextField(
            key: const ValueKey('tavern-channel-model-search'),
            autocorrect: false,
            onChanged: (text) => setState(() => _query = text.trim()),
            decoration: InputDecoration(
              prefixIcon: const Icon(AppIcons.search, size: 20),
              hintText: l10n.tavernChannelSearchModels,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) => ListTile(
              key: ValueKey('tavern-channel-model-${shown[i]}'),
              title: Text(shown[i], style: AppType.mono(size: 14)),
              trailing: shown[i] == widget.current ? const Icon(AppIcons.selected, size: 18) : null,
              onTap: () => Navigator.of(context).pop(shown[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 酒馆设置 › 辅助模型: where 导演, picking who speaks in a group and secrets
/// go. 自动 leaves it to the engine (the main channel; DeepSeek's flash on
/// DeepSeek); a cheaper channel saves on them.
class TavernAuxiliaryTile extends ConsumerWidget {
  const TavernAuxiliaryTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(tavernSettingsProvider);
    final helper = settings.auxiliaryChannel;
    return SettingsTile(
      key: const ValueKey('tavern-auxiliary'),
      icon: AppIcons.agentLoop,
      title: l10n.tavernAuxiliary,
      value: Text(switch (settings.auxiliary) {
        tavernAuxiliaryDeepSeek => l10n.tavernAuxiliaryDeepSeek,
        _ when helper != null => helper.name,
        _ => l10n.tavernAuxiliaryAuto,
      }),
      onTap: () => unawaited(_pickAuxiliary(context)),
    );
  }
}

Future<void> _pickAuxiliary(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (inner, ref, _) {
      final l10n = inner.l10n;
      final settings = ref.watch(tavernSettingsProvider);
      Widget row(String key, String title, String? subtitle, String? id) => SettingsTile(
        key: ValueKey('tavern-auxiliary-$key'),
        title: title,
        subtitle: subtitle,
        trailing: SelectionTick(checked: settings.auxiliary == id),
        onTap: () {
          Navigator.of(sheet).pop();
          unawaited(ref.read(tavernSettingsProvider.notifier).setAuxiliary(id));
        },
      );
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernAuxiliary),
            // What it is for, said where it is chosen; the settings row keeps to its value.
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 4, 0, SheetTitleBar.inset, 12),
              child: Text(
                l10n.tavernAuxiliaryNote,
                style: Theme.of(inner).textTheme.bodySmall?.copyWith(color: DshColors.of(inner).textTertiary),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    row('auto', l10n.tavernAuxiliaryAuto, l10n.tavernAuxiliaryAutoNote, null),
                    row(
                      'deepseek',
                      l10n.tavernAuxiliaryDeepSeek,
                      l10n.tavernChannelDeepSeekNote,
                      tavernAuxiliaryDeepSeek,
                    ),
                    for (final c in settings.channels) row(c.id, c.name, '${c.host} · ${c.model}', c.id),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  ),
);
