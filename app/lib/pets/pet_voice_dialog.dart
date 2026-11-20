// Foreground fallback when Android refuses/silences the overlay microphone.
// It uses chat's recorder/controller, the phone's offline model, and its own
// text field so no existing chat draft is replaced or sent.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/connection_state.dart';
import '../state/voice_settings.dart';
import '../state/voice_state.dart';
import '../ui/chat/voice/voice_controller.dart';
import '../ui/theme/app_icons.dart';
import '../voice/voice_model_assets.dart';

class PetVoiceDialog extends ConsumerStatefulWidget {
  const PetVoiceDialog({super.key, required this.text});
  final String text;
  @override
  ConsumerState<PetVoiceDialog> createState() => _PetVoiceDialogState();
}

class _PetVoiceDialogState extends ConsumerState<PetVoiceDialog> with WidgetsBindingObserver {
  late final TextEditingController _input;
  late final VoiceInputController _voice;
  String? _message;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input = TextEditingController(text: widget.text)..selection = TextSelection.collapsed(offset: widget.text.length);
    _voice =
        VoiceInputController(
            input: _input,
            bridge: ref.read(voiceBridgeProvider),
            client: () => mounted ? ref.read(localConnectionProvider).value?.client : null,
            mode: () async => VoiceMode.engine,
            requiredProviderId: voiceModelProviderId,
            modelReady: () => true,
            onRecognized: () => scheduleMicrotask(_return),
          )
          ..onMessage = (message) {
            if (mounted) setState(() => _message = message.text);
          };
    _voice.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start() {
    if (!mounted || _started || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    _started = true;
    unawaited(_voice.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _start();
  }

  void _return() {
    if (mounted) Navigator.of(context).pop(_input.text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_changed);
    _voice.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(appL10n.petActionVoiceTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(controller: _input, maxLines: 4, minLines: 2, enabled: !_voice.active),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
      ],
    ),
    actions: [
      TextButton(onPressed: _return, child: Text(appL10n.petActionVoiceReturn)),
      FilledButton.icon(
        onPressed: _voice.phase == VoicePhase.transcribing || _voice.phase == VoicePhase.starting
            ? null
            : () => _voice.active ? unawaited(_voice.stop()) : unawaited(_voice.start()),
        icon: Icon(_voice.active ? AppIcons.stop : AppIcons.voice),
        label: Text(_voice.active ? appL10n.petActionVoiceStop : appL10n.petActionVoiceStart),
      ),
    ],
  );
}
