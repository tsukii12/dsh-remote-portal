// Keeps the voice model controller alive with the shell, so the download the
// person chose during setup starts once the engine is up and goes on after a
// restart. Says when it starts, when voice input is ready and why it failed
// (with 重试); the engine notification carries the progress while the app is
// away. Draws nothing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/voice_model_state.dart';
import '../common/brief_notice.dart';
import '../settings/voice_settings_page.dart';

class VoiceModelHost extends ConsumerStatefulWidget {
  const VoiceModelHost({super.key});

  @override
  ConsumerState<VoiceModelHost> createState() => _VoiceModelHostState();
}

class _VoiceModelHostState extends ConsumerState<VoiceModelHost> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<VoiceModelEvent>? _events;

  VoiceModelController get _controller => ref.read(voiceModelProvider.notifier);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () => _controller.setForeground(false),
      onShow: () => _controller.setForeground(true),
    );
    _events = _controller.events.listen(_show);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _show(VoiceModelEvent event) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = context.l10n;
    switch (event.kind) {
      case VoiceModelEventKind.started:
        final size = voiceModelMegabytes(event.bytes);
        messenger.showBriefNotice(event.resumed ? l10n.voiceModelResumedToast(size) : l10n.voiceModelStartedToast(size));
      case VoiceModelEventKind.ready:
        messenger.showBriefNotice(l10n.voiceModelReadyToast);
      case VoiceModelEventKind.failed:
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.voiceModelFailedToast(voiceModelFailureText(l10n, event.failure, neededBytes: event.neededBytes)),
              ),
              // Goes by itself: the reason and 重试 stay on the voice settings page.
              persist: false,
              duration: const Duration(seconds: 8),
              // Asks about mobile data first, as the settings page does: the line may have changed since.
              // A failed 重新下载 kept the model in place: 重试 asks for the whole model again.
              action: SnackBarAction(
                label: l10n.commonRetry,
                onPressed: () => unawaited(downloadVoiceModel(context, ref, again: event.again)),
              ),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The notification follows the app's language.
    _controller.noticeText = VoiceModelNoticeText(
      downloading: l10n.voiceModelNoticeDownloading,
      preparing: l10n.voiceModelNoticePreparing,
      ready: l10n.voiceModelReadyToast,
      failed: l10n.voiceModelNoticeFailed,
    );
    ref.watch(voiceModelProvider.select((_) => null));
    return const SizedBox.shrink();
  }
}
