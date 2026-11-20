import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_sheet.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../theme/app_icons.dart';
import 'bot_file_text_body.dart';
import 'bot_action_scope.dart';

/// Opens the owning sheet before reading, so a delayed file never opens a new
/// route over a conversation the user has since moved to.
Future<void> showRoomFullText(
  BuildContext context,
  WidgetRef ref,
  String roomId,
  DsBotItem item, {
  BotActionScope? scope,
}) async {
  if (scope != null && !scope.connected(context, ref)) return;
  final api = ref.read(dsBotProvider.notifier).api;
  final origin = ref.read(dsBotProvider);
  final whole = item.whole;
  if (api == null || whole == null || !origin.ready || origin.team?.room(roomId) == null) return;
  await showAppSheet<void>(
    context,
    heightFactor: 0.85,
    builder: (_) => _FullText(api: api, origin: origin, roomId: roomId, item: item, whole: whole),
  );
}

class _FullText extends ConsumerStatefulWidget {
  const _FullText({
    required this.api,
    required this.origin,
    required this.roomId,
    required this.item,
    required this.whole,
  });
  final DsBotApi api;
  final DsBotStatus origin;
  final String roomId;
  final DsBotItem item;
  final DsBotLongText whole;

  @override
  ConsumerState<_FullText> createState() => _FullTextState();
}

class _FullTextState extends ConsumerState<_FullText> {
  bool _retired = false;
  bool _loading = false;
  DsBotFileText? _text;
  String? _error;
  StreamSubscription<DsBotFeedEvent>? _feed;
  ProviderSubscription<DsBotStatus>? _status;

  bool _sameTarget() {
    if (!mounted || _retired) return false;
    final status = ref.read(dsBotProvider);
    return identical(widget.api, ref.read(dsBotProvider.notifier).api) &&
        status.host == widget.origin.host &&
        status.hello?.boot == widget.origin.hello?.boot &&
        status.ready &&
        status.team?.room(widget.roomId) != null;
  }

  void _retire() {
    if (mounted && !_retired) setState(() => _retired = true);
  }

  @override
  void initState() {
    super.initState();
    if (!_sameTarget()) _retired = true;
    // Remember retirement, even if the user returns A -> B -> A before a read ends.
    _status = ref.listenManual(dsBotProvider, (_, _) {
      if (!_sameTarget()) _retire();
    });
    final boot = widget.origin.hello?.boot;
    _feed = ref.read(dsBotProvider.notifier).events.listen((event) {
      if (event case DsBotFeedHello(boot: final next?)
          when boot != null && boot.isNotEmpty && next.isNotEmpty && next != boot) {
        _retire();
      }
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading || !_sameTarget()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await widget.api.readFileText(widget.whole);
      if (_sameTarget()) setState(() => _text = text);
    } catch (error) {
      if (_sameTarget()) setState(() => _error = describeDsBotError(error));
    } finally {
      if (_sameTarget()) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _status?.close();
    unawaited(_feed?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _sameTarget();
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(current ? widget.item.name ?? l10n.botsFullText : l10n.botsFullText),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: !current
                ? FeatureMessage(
                    key: const ValueKey('room-full-text-retired'),
                    icon: AppIcons.disconnected,
                    title: l10n.botsFullTextChanged,
                    body: l10n.botsFullTextReopen,
                  )
                : _loading
                ? const QuietSpinner()
                : _error != null
                ? FeatureMessage(
                    icon: AppIcons.error,
                    title: l10n.botsFullTextReadFailed,
                    body: _error,
                    action: (l10n.commonRetry, _load),
                  )
                : BotFileTextBody(value: _text ?? const DsBotFileText('')),
          ),
        ),
      ],
    );
  }
}
