// 模型上下文长度 (a form page): how much one model of a subscription route
// holds. The installed pi-ai catalog sizes every model it ships; this page
// writes a field-by-field override at
// `llm-pi-ai.providers.<route>.modelOverrides.<modelId>.contextWindow` — the
// only way to correct one model's figure without restating the route's model
// list. An empty field means "use the catalog's" and drops the override.
//
// The written value sizes the engine's own context accounting (compaction and
// the usage sheet), not just this screen: it takes effect on the next request.

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers_state.dart';
import '../../state/subscriptions_state.dart';
import '../common/smooth_size.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'provider_model_page.dart' show CapsuleGrid, ChoiceCapsule, contextPresets;
import 'provider_widgets.dart';

/// 订阅渠道里一个模型的「上下文长度」：空着用渠道目录的值，填了就覆盖。
class ModelContextPage extends ConsumerStatefulWidget {
  const ModelContextPage({
    super.key,
    required this.subscription,
    required this.route,
    required this.modelId,
    required this.modelName,
    this.current,
  });

  final Subscription subscription;

  /// The pi-ai route (`openai-codex`, `anthropic`).
  final String route;
  final String modelId;
  final String modelName;

  /// The override as it stands, when this model has one.
  final ModelOverride? current;

  @override
  ConsumerState<ModelContextPage> createState() => _ModelContextPageState();
}

class _ModelContextPageState extends ConsumerState<ModelContextPage> {
  late int? _context = widget.current?.contextWindow;
  late final _text = TextEditingController(text: _context == null ? '' : formatTokens(_context!));
  String? _error;
  String? _formError;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _typed(String raw) {
    setState(() {
      _context = parseTokenCount(raw);
      _error = raw.trim().isEmpty ? null : tokenCountError(raw);
      _formError = null;
    });
  }

  /// 点一次填上；再点一次清空（回到目录值）。
  void _pick(int preset) {
    setState(() {
      _context = _context == preset ? null : preset;
      _text.text = _context == null ? '' : formatTokens(_context!);
      _error = null;
      _formError = null;
    });
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final typed = _text.text.trim();
    final value = typed.isEmpty ? null : parseTokenCount(typed);
    if (typed.isNotEmpty && value == null) {
      setState(() => _error = appL10n.stateProviderTokenCountInvalid);
      return;
    }
    final backend = ref.read(providerBackendProvider);
    if (backend == null) return;
    // 保留这条覆盖上的其他字段（名称、输出上限……），只改上下文长度。
    final next = (widget.current ?? const ModelOverride()).withContextWindow(value);
    final profile = ref.read(subscriptionProfileProvider(widget.subscription)).value;
    final last = (profile?.modelOverrides.length ?? 2) <= 1;
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      if (next.isEmpty) {
        await backend.clearModelOverride(widget.route, widget.modelId, last: last);
      } else {
        await backend.setModelOverride(widget.route, widget.modelId, next);
      }
      if (!mounted) return;
      ref.invalidate(subscriptionProfileProvider(widget.subscription));
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _formError = context.l10n.engineProviderSaveFailed(describeProviderError(error)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    final page = AppPage.list(
      title: widget.modelName,
      subtitle: widget.modelName == widget.modelId ? null : Text(widget.modelId),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.engineModelTokenLimits,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.engineModelContextLength,
                      error: _error,
                      below: CapsuleGrid(
                        columns: contextPresets.length,
                        children: [
                          for (final preset in contextPresets)
                            ChoiceCapsule(
                              label: formatTokens(preset),
                              selected: _context == preset,
                              onTap: _saving ? null : () => _pick(preset),
                            ),
                        ],
                      ),
                      child: TextField(
                        controller: _text,
                        enabled: !_saving,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        onChanged: _typed,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9kKmM., _]')),
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: InputDecoration(
                          hintText: l10n.commonDefault,
                          error: _error == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 0, SettingsMetrics.inset, 16),
              child: Text(
                l10n.engineModelContextOverrideHint,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ),
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
          ],
        ),
      ],
    );
    return Stack(
      children: [
        page,
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: FormBottomBar(
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.engineProviderSaving),
                      ],
                    )
                  : Text(l10n.commonSave),
            ),
          ),
        ),
      ],
    );
  }
}
