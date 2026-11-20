import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/phone_channel.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'sessions_state.dart';

/// UI provenance only. Native independently binds its original attachment/root.
class PhoneSkillUseOrigin {
  const PhoneSkillUseOrigin._(this.client, this.generation, this.sessionId, this.selectionRevision);
  final DshClient client;
  final MuxGeneration generation;
  final String sessionId;
  final int selectionRevision;

  static PhoneSkillUseOrigin? capture(ProviderContainer container, String sessionId) {
    final active = container.read(activeConnectionProvider);
    final local = container.read(localConnectionProvider);
    if (container.read(activeHostProvider) != HostRef.none || active.isLoading || active.hasError ||
        local.isLoading || local.hasError || active.value?.isLocal != true || local.value?.isLocal != true ||
        container.read(currentSessionProvider) != sessionId) {
      return null;
    }
    final client = local.value!.client;
    final generation = client.mux.generation;
    if (!identical(active.value?.client, client) || generation == null) return null;
    return PhoneSkillUseOrigin._(client, generation, sessionId,
      container.read(currentSessionProvider.notifier).selectionRevision);
  }

  bool current(ProviderContainer container) {
    final now = capture(container, sessionId);
    return now != null && identical(now.client, client) && identical(now.generation, generation) &&
      now.selectionRevision == selectionRevision;
  }
}

/// One prepared choice, handed to the composer without replacing its source.
class PreparedPhoneSkill {
  const PreparedPhoneSkill({required this.origin, required this.ready, required this.channel, required this.text});
  final PhoneSkillUseOrigin origin;
  final PhoneSkillReplayReady ready;
  final PhoneChannel channel;
  final String text;
  Future<bool> discard() => channel.discardSkillReplay(ready.invocation);
}
