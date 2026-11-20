// User actions from the floating pet. Offers pin the host, connection and
// generation; sending still goes through ChatController, including sync,
// history, prompt receipts and retries. No background host is selected here.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/chat_state.dart';
import '../state/compose_inbox.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart';
import '../state/sessions_state.dart';
import '../voice/voice_model_assets.dart';
import 'overlay_channel.dart';
import 'pet_signals.dart';
import 'pet_state.dart';

/// Unlike persisted host preferences, an action must never decode malformed
/// input as permission to act on the local engine.
HostRef? petActionHost(Object? raw) {
  if (raw is! String) return null;
  try {
    final m = jsonDecode(raw);
    if (m is! Map || m['id'] is! String || (m['id'] as String).isEmpty) return null;
    return m['kind'] == 'portal' ? HostRef.portal(m['id'] as String) : null;
  } catch (_) {
    return null;
  }
}

final petHostChoicesProvider = Provider<List<PetHostChoice>>((ref) {
  final current = ref.watch(activeHostProvider);
  final hosts = <(HostRef, String)>[
    for (final h in ref.watch(hostsProvider).portals)
      (HostRef.portal(h.id, name: h.name), h.name),
  ];
  return [for (final (host, label) in hosts) PetHostChoice(host, snippet(label, max: 40)!, current: host == current)];
});

class _AskOffer {
  _AskOffer(this.id, this.host, this.connection, this.generation, this.sessionId);
  final int id;
  final HostRef host;
  final HostConnection? connection;
  final MuxGeneration? generation;
  final String? sessionId;
  String? created;
}

class PetOverlayActions {
  PetOverlayActions(this.ref);
  final Ref ref;
  _AskOffer? _offer;
  int _next = 0;
  bool _sending = false;

  bool _current(_AskOffer offer) =>
      ref.mounted &&
      ref.read(activeHostProvider) == offer.host &&
      identical(ref.read(activeConnectionProvider).value, offer.connection) &&
      identical(offer.connection?.client.mux.generation, offer.generation);

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'askTarget':
        return _target();
      case 'ask':
        return _send(args);
      case 'answer':
        final host = petActionHost(args['host']);
        final event = args['eventId'];
        final session = args['sessionId'];
        final token = args['token'];
        final decision = switch (args['decision']) {
          'allow' => ApprovalDecision.allowOnce,
          'reject' => ApprovalDecision.reject,
          _ => null,
        };
        final kind = args['kind'];
        if (host == null ||
            event is! String ||
            session is! String ||
            token is! int ||
            (kind != 'approval' && kind != 'question') ||
            (kind == 'approval' && decision == null) ||
            (kind == 'question' && args['choice'] is! String)) {
          return {'result': 'failed'};
        }
        final result = await ref
            .read(chatAlertsProvider.notifier)
            .answerFromPet(
              host,
              event,
              sessionId: session,
              token: token,
              decision: kind == 'approval' ? decision : null,
              choice: kind == 'question' ? args['choice'] as String : null,
            );
        return {'result': result.name};
      case 'transcribe':
        return _transcribe(args['wav']);
      case 'switchHost':
        final host = petActionHost(args['host']);
        if (host == null || !ref.read(petHostChoicesProvider).any((h) => h.host == host)) return false;
        ref.read(activeHostProvider.notifier).select(host);
        _offer = null;
        return true;
      case 'stop':
        final host = petActionHost(args['host']);
        final session = args['sessionId'];
        if (host != ref.read(activeHostProvider) || session is! String) return false;
        final target = ref.read(petStateProvider).target;
        if (target != PetTarget(host!, session)) return false;
        final chat = ref.read(chatProvider(session).notifier);
        if (!await chat.waitForSync() || !ref.mounted || ref.read(activeHostProvider) != host) return false;
        final returned = await chat.cancel();
        if (ref.mounted) {
          for (final prompt in returned) {
            ref
                .read(composeInboxProvider.notifier)
                .push(ComposeRequest(text: prompt.text, attachments: prompt.attachments));
          }
        }
        return true;
      default:
        return null;
    }
  }

  Future<Map<String, Object?>> _target() async {
    final host = ref.read(activeHostProvider);
    final connection = ref.read(activeConnectionProvider).value;
    final generation = connection?.client.mux.generation;
    final pet = ref.read(petStateProvider).target;
    final sessions = ref.read(sessionsProvider).value ?? const <SessionSummary>[];
    final session = pet?.host == host
        ? sessions.where((s) => s.sessionId == pet!.sessionId && !s.running && s.agentAvailable).firstOrNull
        : null;
    final offer = _AskOffer(++_next, host, connection, generation, session?.sessionId);
    _offer = offer;
    final voice = await _voice();
    final label = snippet(connection?.label ?? hostLabel(host.kind, host.name), max: 40)!;
    return {
      'offer': offer.id,
      'fresh': {'host': host.encode(), 'line': '${appL10n.commonNewChat} · $label'},
      if (session != null)
        'current': {
          'host': host.encode(),
          'sessionId': session.sessionId,
          'line': '${snippet(session.title, max: 20) ?? appL10n.commonUntitledChat} · $label',
        },
      if (connection == null || generation == null) 'problem': appL10n.commonEngineUnreachable,
      'voice': ref.read(localConnectionProvider).value?.client.mux.generation == null
          ? 'off'
          : voice == null
          ? 'missing'
          : 'ready',
    };
  }

  Future<Map<String, Object?>> _send(Map args) async {
    Map<String, Object?> problem(String text) => {'problem': text};
    final offer = _offer;
    final text = args['text'];
    final fresh = args['fresh'] == true;
    if (_sending) return problem(appL10n.petActionSending);
    if (offer == null ||
        args['offer'] != offer.id ||
        !_current(offer) ||
        petActionHost(args['host']) != offer.host ||
        (!fresh && args['sessionId'] != offer.sessionId) ||
        (!fresh && offer.sessionId == null)) {
      return problem(appL10n.petActionTargetChanged);
    }
    if (offer.connection == null || offer.generation == null) return problem(appL10n.commonEngineUnreachable);
    if (text is! String || text.trim().isEmpty || text.length > 4000) return problem(appL10n.petActionSendFailed);
    _sending = true;
    try {
      final id = fresh ? offer.created ??= await ref.read(sessionsProvider.notifier).create() : offer.sessionId!;
      if (!_current(offer)) return problem(appL10n.petActionTargetChanged);
      final chat = ref.read(chatProvider(id).notifier);
      if (!await chat.waitForSync(isCurrent: () => _current(offer)) || !_current(offer)) {
        return problem(appL10n.commonEngineUnreachable);
      }
      final state = ref.read(chatProvider(id));
      if (state.running || state.openApproval != null || state.questions.isNotEmpty) {
        return problem(appL10n.petActionBusy);
      }
      final target = PetTarget(offer.host, id);
      ref.read(petAskedProvider.notifier).add(target);
      final sent = await chat.send(text);
      if (!ref.mounted) return problem(appL10n.petActionSendFailed);
      if (!sent) {
        ref.read(petAskedProvider.notifier).take(target);
        return problem(
          _current(offer)
              ? ref.read(chatProvider(id)).error ?? appL10n.petActionSendFailed
              : appL10n.petActionTargetChanged,
        );
      }
      return {'sent': true, 'sessionId': id, 'host': offer.host.encode()};
    } catch (_) {
      return problem(appL10n.petActionSendFailed);
    } finally {
      _sending = false;
    }
  }

  /// Only the phone's installed SenseVoice model. A remote or cloud selection
  /// must never silently receive a recording from the floating microphone.
  Future<(DshClient, SpeechCatalog, MuxGeneration)?> _voice() async {
    final client = ref.read(localConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    if (client == null || generation == null) return null;
    try {
      final catalog = await client.speechCatalog().timeout(const Duration(seconds: 4));
      if (!ref.mounted ||
          !identical(ref.read(localConnectionProvider).value?.client, client) ||
          !identical(generation, client.mux.generation)) {
        return null;
      }
      final model = catalog?.providers
          .where((p) => p.id == voiceModelProviderId && p.location == 'host-local' && p.usable)
          .firstOrNull;
      return model == null ? null : (client, catalog!, generation);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>> _transcribe(Object? wav) async {
    final voice = await _voice();
    if (voice == null) return {'problem': appL10n.petActionVoiceMissing};
    if (wav is! Uint8List || wav.length < 9644 || wav.length > voice.$2.maxAudioBytes) {
      return {'problem': appL10n.chatVoiceNotHeard};
    }
    try {
      final result = await voice.$1.transcribe(wav, providerId: voiceModelProviderId, language: voice.$2.language);
      if (!ref.mounted ||
          !identical(ref.read(localConnectionProvider).value?.client, voice.$1) ||
          !identical(voice.$3, voice.$1.mux.generation)) {
        return {'problem': appL10n.commonEngineUnreachable};
      }
      return {'text': result.text};
    } catch (_) {
      return {'problem': appL10n.chatVoiceNotHeard};
    }
  }
}

final petOverlayActionsProvider = Provider<PetOverlayActions>((ref) => PetOverlayActions(ref));

final petOverlayActionBridgeProvider = Provider<void>((ref) {
  final channel = ref.watch(petOverlayChannelProvider);
  final actions = ref.watch(petOverlayActionsProvider);
  channel.setActionHandler(actions.handle);
  ref.onDispose(() => channel.setActionHandler(null));
});
