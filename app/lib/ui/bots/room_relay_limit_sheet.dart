// The user's guard against an endlessly relaying group. Null means the server
// default, never unlimited; the API must preserve that explicit null.
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';
import 'bot_action_scope.dart';

Future<void> showRoomRelayLimitSheet(BuildContext context, DsBotRoom room, {BotActionScope? scope, WidgetRef? ref}) {
  if (scope != null && (ref == null || !scope.connected(context, ref))) return Future.value();
  return showAppSheet<void>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (_) => RoomRelayLimitSheet(room: room, scope: scope),
  );
}

class RoomRelayLimitSheet extends ConsumerStatefulWidget {
  const RoomRelayLimitSheet({super.key, required this.room, this.scope});
  final DsBotRoom room;
  final BotActionScope? scope;

  @override
  ConsumerState<RoomRelayLimitSheet> createState() => _RoomRelayLimitSheetState();
}

class _RoomRelayLimitSheetState extends ConsumerState<RoomRelayLimitSheet> {
  late final _input = TextEditingController(text: widget.room.relayLimit?.toString() ?? '');
  late final DsBotApi? _api;
  late final BotActionScope _scope;
  bool _saving = false;
  String? _error;

  // Capture the connection when the sheet opens, before any later host change.
  @override
  void initState() {
    super.initState();
    _scope = widget.scope ?? BotActionScope(ref, roomId: widget.room.id);
    _api = _scope.api;
  }

  bool get _current => mounted && _scope.connected(context, ref);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _valid {
    final text = _input.text.trim();
    final value = int.tryParse(text);
    return text.isEmpty || (RegExp(r'^\d+$').hasMatch(text) && value != null && value >= 1 && value <= 200);
  }

  Future<void> _save(int? value) async {
    final status = ref.read(dsBotProvider);
    if (_saving || _api == null || !_current || status.readOnly != null || status.team?.room(widget.room.id) == null) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.setRoomRelayLimit(widget.room.id, value);
      if (!_current) return;
      await ref.read(dsBotProvider.notifier).refresh();
      if (mounted && _current) Navigator.of(context).pop();
    } catch (error) {
      if (_current) setState(() => _error = describeDsBotError(error));
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final current = _current;
    final writable = current && status.readOnly == null && status.team?.room(widget.room.id) != null;
    final enabled = writable && !_saving;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.botsRelayLimit),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.botsRelayLimitHint),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('relay-limit-input'),
                      controller: _input,
                      enabled: enabled,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() => _error = null),
                      decoration: InputDecoration(
                        labelText: l10n.botsRelayLimit,
                        hintText: widget.room.relayLimitDefault?.toString(),
                        errorText: _valid ? null : l10n.botsRelayLimitInvalid,
                        helperText: widget.room.relayLimitDefault == null
                            ? null
                            : l10n.botsRelayLimitDefault(widget.room.relayLimitDefault!),
                      ),
                    ),
                    if (!current || _error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        current ? _error! : l10n.botsRelayLimitConnectionChanged,
                        style: TextStyle(color: DshColors.of(context).danger),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('relay-limit-save'),
                      onPressed: enabled && _valid ? () => _save(int.tryParse(_input.text.trim())) : null,
                      child: Text(l10n.commonSave),
                    ),
                    TextButton(
                      key: const ValueKey('relay-limit-default'),
                      onPressed: enabled && widget.room.relayLimit != null ? () => _save(null) : null,
                      child: Text(l10n.botsRelayLimitRestore),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
