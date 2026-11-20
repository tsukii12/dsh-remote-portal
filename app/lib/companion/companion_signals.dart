/// C760 pure admission, preview and one-shot sharing. No widget, model call,
/// timers, history subscription, memory writes or phone collector lives here.
library;

import 'dart:collection';

import 'package:dsh_client/dsh_client.dart';

final class CompanionSignalConsent {
  const CompanionSignalConsent({
    this.state = false,
    this.optionalSpeech = false,
    this.voice = false,
    this.nightCare = false,
  });
  final bool state, optionalSpeech, voice, nightCare;
}

/// Actual object identity belongs to the attachment owner. Host strings are
/// display/dedup keys only. Make a new source when the connection changes.
final class CompanionSignalSource {
  CompanionSignalSource.dsh({
    required this.hostKey,
    required DshClient client,
    required Object this.connection,
    required this.isAttached,
    this.runCapability,
  }) : client = client,
       localOwner = null,
       generation = client.mux.generation {
    if (!companionSignalId(hostKey) || generation == null || (runCapability != null && !runCapability!.isFor(client))) {
      throw ArgumentError('source requires the actual ready client');
    }
  }
  CompanionSignalSource.local({required Object owner, required this.isAttached})
    : localOwner = owner,
      hostKey = 'local-device',
      client = null,
      connection = null,
      generation = null,
      runCapability = null;
  final String hostKey;
  final DshClient? client;
  final Object? connection, localOwner;
  final MuxGeneration? generation;
  final CompanionSignalCapabilities? runCapability;
  final bool Function() isAttached;
  bool get isLocal => localOwner != null;
  bool _pure() => isLocal || identical(client!.mux.generation, generation);
}

final class CompanionSignalIngress {
  CompanionSignalIngress._(this._gate, this.source, this.recipientContext, this.ownerEpoch, this.consentRevision);
  final CompanionSignalGate _gate;
  final CompanionSignalSource source;
  final Object recipientContext, ownerEpoch;
  final int consentRevision;
}

enum CompanionSignalAdmission { accepted, cleared, duplicate, throttled, stale, unavailable, rejected, capacity }

final class CompanionSignalSlot {
  CompanionSignalSlot._(
    this.signal,
    this._ingress,
    this._key,
    this.receivedAtMonoMs,
    this.expiresAtMonoMs,
    this._provenance,
    this._run,
    this._pending,
  );
  final CompanionSignalV1 signal;
  final CompanionSignalIngress _ingress;
  final Object _key;
  final MuxEventProvenance? _provenance;
  final CompanionRunReceipt? _run;
  final bool Function()? _pending;
  final int receivedAtMonoMs, expiresAtMonoMs;
  int get speechExpiresAtMonoMs => receivedAtMonoMs + 120000;
  Object get recipientContext => _ingress.recipientContext;
  String? get nightKey => signal.kind == 'app.late_use' ? signal.payload['nightKey'] as String : null;
}

final class CompanionSignalSpeech {
  CompanionSignalSpeech._(this.id, this.slot, this.text, this.voice, this.nightCare);
  final String id;
  final CompanionSignalSlot slot;
  final String text;
  final bool voice, nightCare;
  int get expiresAtMonoMs => slot.speechExpiresAtMonoMs;
  Object get recipientContext => slot.recipientContext;
  String? get nightKey => slot.nightKey;
}

final class CompanionSignalPreview {
  CompanionSignalPreview._(this._gate, this.slot, this.text, this.localDetail);
  final CompanionSignalGate _gate;
  final CompanionSignalSlot slot;
  final String text;
  final bool localDetail;
}

sealed class CompanionShareTarget {
  CompanionShareTarget._(this.recipientContext, this.targetEpoch, this.currentTargetEpoch);
  final Object recipientContext;
  final Object targetEpoch;
  final Object? Function() currentTargetEpoch;
  bool _retired = false;
  void retire() => _retired = true;
  bool get isCurrent => _readTargetCurrent(this);
}

final class CompanionLightShareTarget extends CompanionShareTarget {
  CompanionLightShareTarget({
    required Object recipientContext,
    required Object targetEpoch,
    required Object? Function() currentTargetEpoch,
    required this.keeper,
    required this.modelConfiguration,
    required this.currentKeeper,
    required this.currentModelConfiguration,
  }) : super._(recipientContext, targetEpoch, currentTargetEpoch);
  final Object keeper, modelConfiguration;
  final Object? Function() currentKeeper, currentModelConfiguration;
}

final class CompanionFullShareTarget extends CompanionShareTarget {
  CompanionFullShareTarget({
    required Object recipientContext,
    required Object targetEpoch,
    required Object? Function() currentTargetEpoch,
    required this.client,
    required this.connection,
    required this.capabilities,
    required this.binding,
    required this.currentClient,
    required this.currentConnection,
    required this.currentBinding,
  }) : generation = client.mux.generation,
       super._(recipientContext, targetEpoch, currentTargetEpoch);
  final DshClient client;
  final Object connection;
  final MuxGeneration? generation;
  final CompanionRecallCapabilities capabilities;
  final CompanionRecallBinding binding;
  final DshClient? Function() currentClient;
  final Object? Function() currentConnection;
  final CompanionRecallBinding? Function() currentBinding;
}

final class CompanionSharePermit {
  CompanionSharePermit._(this._gate, this.preview, this.target);
  final CompanionSignalGate _gate;
  final CompanionSignalPreview preview;
  final CompanionShareTarget target;
  bool _used = false;
  bool get used => _used;
  Future<CompanionShareResult<T>> dispatch<T>(Future<T> Function(String, CompanionShareTarget, bool Function()) send) =>
      _gate.dispatch(this, send);
}

final class CompanionShareResult<T> {
  const CompanionShareResult(this.accepted, this.value);
  final bool accepted;
  final T? value;
}

/// A gate is scoped to one companion owner. All new consents default off.
/// All source and UI callbacks are untrusted reentry boundaries: local captured
/// state and actual mux identity are checked again after their invocation.
final class CompanionSignalGate {
  CompanionSignalGate({int Function()? monotonicMs, DateTime Function()? utcNow})
    : _clock = monotonicMs ?? companionMonotonicMs,
      _utcNow = utcNow ?? _nowUtc;
  final int Function() _clock;
  final DateTime Function() _utcNow;
  Object? _recipient, _owner;
  int _revision = 0, _lastNow = -1, _nonce = 0;
  bool _faulted = false, _clearSaturated = false;
  final Map<CompanionSignalSource, CompanionSignalConsent> _consents = Map.identity();
  final LinkedHashMap<Object, CompanionSignalSlot> _slots = LinkedHashMap();
  final Set<Object> _seen = {};
  final Set<Object> _cleared = {};
  final Map<Object, int> _latestSeq = {};
  final Map<Object, int> _latestTurn = {};
  final Map<String, List<int>> _rate = {};
  final Map<String, int> _overflow = {};
  final Map<Object, CompanionShareTarget> _epochs = Map.identity();
  bool get faulted => _faulted;
  int get consentRevision => _revision;
  int overflowCount(String hostKey) => _overflow[hostKey] ?? 0;
  void retireSource(CompanionSignalSource source) => detach(source);
  Map<String, int> get overflowCounts => Map.unmodifiable(_overflow);
  static DateTime _nowUtc() => DateTime.now().toUtc();

  void enter({required Object recipientContext, required Object ownerEpoch}) {
    _recipient = recipientContext;
    _owner = ownerEpoch;
    _revision++;
    _slots.clear();
  }

  void leave() {
    _recipient = null;
    _owner = null;
    _revision++;
    _slots.clear();
  }

  void retire() => leave();
  void setConsent(CompanionSignalSource source, CompanionSignalConsent consent) {
    if (!_consents.containsKey(source) && _consents.length >= 8) return;
    final old = _consents[source];
    if (old != null &&
        old.state == consent.state &&
        old.optionalSpeech == consent.optionalSpeech &&
        old.voice == consent.voice &&
        old.nightCare == consent.nightCare) {
      return;
    }
    _consents[source] = consent;
    _revision++;
    _slots.clear();
  }

  void detach(CompanionSignalSource source) {
    if (_consents.remove(source) != null) {
      _revision++;
      _slots.clear();
    }
  }

  CompanionSignalIngress? openIngress(CompanionSignalSource source) {
    final recipient = _recipient, owner = _owner, revision = _revision;
    if (recipient == null || owner == null || _faulted || _consents[source]?.state != true) return null;
    final ingress = CompanionSignalIngress._(this, source, recipient, owner, revision);
    return _ingressCurrent(ingress) ? ingress : null;
  }

  bool ingressCurrent(CompanionSignalIngress ingress) => _ingressCurrent(ingress);
  bool _ingressPure(CompanionSignalIngress ingress) =>
      !_faulted &&
      identical(ingress._gate, this) &&
      identical(ingress.recipientContext, _recipient) &&
      identical(ingress.ownerEpoch, _owner) &&
      ingress.consentRevision == _revision &&
      _consents[ingress.source]?.state == true &&
      ingress.source._pure();
  bool _ingressCurrent(CompanionSignalIngress ingress) {
    if (!_ingressPure(ingress)) return false;
    bool attached;
    try {
      attached = ingress.source.isAttached();
    } catch (_) {
      attached = false;
    }
    return attached && _ingressPure(ingress);
  }

  int? _now() {
    if (_faulted) return null;
    int value;
    try {
      value = _clock();
    } catch (_) {
      _fault();
      return null;
    }
    if (!companionSignalInteger(value) || value < _lastNow) {
      _fault();
      return null;
    }
    _lastNow = value;
    return value;
  }

  void _fault() {
    _faulted = true;
    _revision++;
    _slots.clear();
  }

  List<CompanionSignalSlot> get slots {
    _prune();
    return List.unmodifiable(_slots.values);
  }

  void _prune() {
    for (final slot in _slots.values.toList()) {
      if (!_slotCurrent(slot) && identical(_slots[slot._key], slot)) _slots.remove(slot._key);
    }
  }

  CompanionSignalAdmission receive(
    CompanionSignalIngress ingress,
    CompanionSignalV1 signal, {
    MuxEventProvenance? provenance,
    bool Function()? stillPending,
    bool Function()? receiptCurrent,
    int ageMs = 0,
  }) {
    if (signal.kind == 'run.result' || signal.kind == 'device.power' || signal.kind.startsWith('notification.')) {
      return CompanionSignalAdmission.unavailable;
    }
    if (!companionSignalInteger(ageMs) || (signal.kind == 'task.approval_waiting' && stillPending == null)) {
      return CompanionSignalAdmission.rejected;
    }
    bool additional() => (stillPending?.call() ?? true) && (receiptCurrent?.call() ?? true);
    return _receive(
      ingress,
      signal,
      provenance,
      null,
      stillPending == null && receiptCurrent == null ? null : additional,
      ageMs,
    );
  }

  CompanionSignalAdmission receiveRun(CompanionSignalIngress ingress, CompanionRunReceipt receipt) {
    final source = ingress.source;
    if (source.isLocal ||
        !identical(source.client, receipt.client) ||
        !identical(source.generation, receipt.muxGeneration) ||
        !identical(source.runCapability, receipt.capability) ||
        source.hostKey != receipt.hostKey ||
        !receipt.capability.available) {
      return CompanionSignalAdmission.unavailable;
    }
    if (!receipt.current || !_ingressPure(ingress)) return CompanionSignalAdmission.stale;
    return _receive(ingress, receipt.signal, null, receipt, null, 0);
  }

  CompanionSignalAdmission _receive(
    CompanionSignalIngress ingress,
    CompanionSignalV1 signal,
    MuxEventProvenance? provenance,
    CompanionRunReceipt? run,
    bool Function()? pending,
    int conservativeAge,
  ) {
    if (!_ingressCurrent(ingress)) return CompanionSignalAdmission.stale;
    final source = ingress.source;
    if (source.isLocal) {
      if (signal.kind != 'app.late_use' || provenance != null || run != null) return CompanionSignalAdmission.rejected;
    } else {
      if (signal.source['type'] != 'dsh' || signal.hostKey != source.hostKey) return CompanionSignalAdmission.rejected;
      if (run == null &&
          (provenance == null ||
              !identical(provenance.mux, source.client!.mux) ||
              !identical(provenance.generation, source.generation) ||
              !provenance.current ||
              signal.observedAt != provenance.observedAt)) {
        return CompanionSignalAdmission.stale;
      }
    }
    final now = _now();
    final actualAge = run?.ageMs ?? provenance?.ageMs ?? 0;
    final age = actualAge > conservativeAge ? actualAge : conservativeAge;
    if (now == null || age < 0 || !_ingressPure(ingress)) return CompanionSignalAdmission.stale;
    final received = now - age;
    final key = _dedupKey(signal, source);
    // Withdraw before rate, normal dedup and capacity admission. A clear for an
    // unseen request still prevents its delayed waiting message from reviving.
    if (signal.kind == 'task.approval_cleared') {
      _slots.remove(key);
      if (_cleared.length < 512 || _cleared.contains(key)) {
        _cleared.add(key);
      } else {
        _clearSaturated = true;
      }
      return CompanionSignalAdmission.cleared;
    }
    if (signal.kind == 'task.approval_waiting' && (_clearSaturated || _cleared.contains(key))) {
      return CompanionSignalAdmission.stale;
    }
    _prune();
    if (!_ingressCurrent(ingress) || !_ingressPure(ingress)) return CompanionSignalAdmission.stale;
    if (_seen.contains(key)) return CompanionSignalAdmission.duplicate;
    if (_seen.length >= 512) {
      _slots.clear();
      return CompanionSignalAdmission.capacity;
    }
    if (received < 0 ||
        (signal.kind == 'app.late_use'
            ? now - received >= 120000
            : signal.kind == 'task.approval_waiting'
            ? false
            : now - received >= 600000)) {
      return CompanionSignalAdmission.stale;
    }
    if (signal.kind == 'task.approval_waiting' && pending == null) return CompanionSignalAdmission.rejected;
    final seqKey = _sequenceKey(signal, source);
    final sessionKey = (source.hostKey, signal.sessionId);
    if (signal.seq != null) {
      final latest = _latestSeq[seqKey];
      if ((latest != null && signal.seq! <= latest) ||
          (signal.turn != null && signal.turn! < (_latestTurn[sessionKey] ?? 0))) {
        return CompanionSignalAdmission.stale;
      }
      // A newer fact retires stale success even if admission later hits rate.
      _latestSeq[seqKey] = signal.seq!;
      if (signal.turn != null && signal.turn! > (_latestTurn[sessionKey] ?? 0)) _latestTurn[sessionKey] = signal.turn!;
      for (final old in _slots.values.toList()) {
        if (old.signal.hostKey == signal.hostKey &&
            old.signal.sessionId == signal.sessionId &&
            (_sequenceKey(old.signal, old._ingress.source) == seqKey ||
                (old.signal.turn != null && signal.turn != null && old.signal.turn! < signal.turn!))) {
          if (identical(_slots[old._key], old)) _slots.remove(old._key);
        }
      }
    }
    _seen.add(key);
    if (signal.seq != null) {
      final times = _rate.putIfAbsent(source.hostKey, () => []);
      times.removeWhere((time) => now - time >= 60000);
      if (times.length >= 10) {
        _overflow[source.hostKey] = (_overflow[source.hostKey] ?? 0) + 1;
        return CompanionSignalAdmission.throttled;
      }
      times.add(now);
    }
    final ttl = signal.kind == 'task.approval_waiting'
        ? 9007199254740991
        : received + (signal.kind == 'app.late_use' ? 120000 : 600000);
    final slot = CompanionSignalSlot._(signal, ingress, key, received, ttl, provenance, run, pending);
    // Temporarily install to let the complete final validator use identity.
    if (_slots.length >= 8) _slots.remove(_slots.keys.first);
    _slots[key] = slot;
    if (!_slotCurrent(slot)) {
      if (identical(_slots[key], slot)) _slots.remove(key);
      return CompanionSignalAdmission.stale;
    }
    return CompanionSignalAdmission.accepted;
  }

  Object _dedupKey(CompanionSignalV1 signal, CompanionSignalSource source) => switch (signal.kind) {
    'task.terminal' => ('terminal', source.hostKey, signal.sessionId, signal.seq),
    'run.result' => ('run', source.hostKey, signal.sessionId, signal.source['callId'], signal.seq),
    'task.approval_waiting' ||
    'task.approval_cleared' => ('request', source.hostKey, source.generation, signal.requestId),
    _ => ('local', source.localOwner, signal.id),
  };
  Object _sequenceKey(CompanionSignalV1 signal, CompanionSignalSource source) =>
      (source.hostKey, signal.sessionId, signal.kind, signal.kind == 'run.result' ? signal.source['callId'] : null);
  bool _slotPure(CompanionSignalSlot slot, int now, {bool speech = false}) {
    final signal = slot.signal;
    return identical(_slots[slot._key], slot) &&
        (slot._provenance == null || slot._provenance.current) &&
        (slot._run == null || slot._run.locallyCurrent) &&
        _ingressPure(slot._ingress) &&
        now >= slot.receivedAtMonoMs &&
        now < slot.expiresAtMonoMs &&
        (!speech || now < slot.speechExpiresAtMonoMs) &&
        (signal.seq == null || _latestSeq[_sequenceKey(signal, slot._ingress.source)] == signal.seq) &&
        (signal.turn == null || signal.turn! >= (_latestTurn[(slot._ingress.source.hostKey, signal.sessionId)] ?? 0));
  }

  bool _slotCurrent(CompanionSignalSlot slot, {bool speech = false}) {
    var now = _now();
    if (now == null || !_slotPure(slot, now, speech: speech) || !_ingressCurrent(slot._ingress)) return false;
    if (slot._provenance != null && !slot._provenance.current) return false;
    if (slot._run != null && !slot._run.current) return false;
    if (slot._pending != null) {
      bool pending;
      try {
        pending = slot._pending();
      } catch (_) {
        pending = false;
      }
      if (!pending) return false;
    }
    if (slot.signal.kind == 'app.late_use') {
      DateTime wall;
      try {
        wall = _utcNow().toUtc();
      } catch (_) {
        return false;
      }
      final shifted = wall.add(Duration(minutes: slot.signal.payload['utcOffsetMinutes'] as int));
      if (shifted.hour >= 7 && shifted.hour < 23) return false;
      final night = shifted.hour < 7 ? shifted.subtract(const Duration(days: 1)) : shifted;
      if (night.toIso8601String().substring(0, 10) != slot.nightKey) return false;
    }
    now = _now();
    return now != null && _slotPure(slot, now, speech: speech);
  }

  bool slotCurrent(CompanionSignalSlot slot) => _slotCurrent(slot);

  CompanionSignalSpeech? speechCandidate(CompanionSignalSlot slot, {String language = 'zh'}) {
    if (!_slotCurrent(slot, speech: true) ||
        slot.signal.reconciled ||
        !const {'task.terminal', 'run.result', 'app.late_use'}.contains(slot.signal.kind)) {
      return null;
    }
    final consent = _consents[slot._ingress.source]!;
    if (!consent.optionalSpeech) return null;
    final text = _template(slot.signal, language);
    if (text.runes.length > (language == 'zh' ? 40 : 80)) return null;
    final speech = CompanionSignalSpeech._('signal-${++_nonce}', slot, text, consent.voice, consent.nightCare);
    return speechCurrent(speech) ? speech : null;
  }

  bool speechCurrent(CompanionSignalSpeech speech) =>
      _slotCurrent(speech.slot, speech: true) &&
      _consents[speech.slot._ingress.source]?.optionalSpeech == true &&
      _consents[speech.slot._ingress.source]?.voice == speech.voice &&
      _consents[speech.slot._ingress.source]?.nightCare == speech.nightCare;

  CompanionSignalPreview? previewMetadata(CompanionSignalSlot slot, {String language = 'zh'}) =>
      _slotCurrent(slot) ? CompanionSignalPreview._(this, slot, _template(slot.signal, language), false) : null;

  /// A user-selected DSH result only. The loader receives the exact client,
  /// session and seq; it must not substitute the latest result or scan all chats.
  Future<CompanionSignalPreview?> loadLocalDetail(
    CompanionSignalSlot slot,
    Future<String?> Function(DshClient client, String sessionId, int seq) loader,
  ) async {
    if (!_slotCurrent(slot) || !const {'task.terminal', 'run.result'}.contains(slot.signal.kind)) return null;
    final client = slot._ingress.source.client, session = slot.signal.sessionId, seq = slot.signal.seq;
    if (client == null || session == null || seq == null) return null;
    String? text;
    try {
      text = await loader(client, session, seq);
    } catch (_) {
      return null;
    }
    if (text == null ||
        text.isEmpty ||
        text.length > 4096 ||
        !companionScalarText(text, controls: true) ||
        text.codeUnits.any((u) => (u < 32 && u != 9 && u != 10 && u != 13) || (u >= 127 && u <= 159)) ||
        !_slotCurrent(slot)) {
      return null;
    }
    return CompanionSignalPreview._(this, slot, text, true);
  }

  bool _targetPure(CompanionShareTarget target) =>
      !target._retired &&
      identical(_epochs[target.targetEpoch], target) &&
      (target is! CompanionFullShareTarget ||
          (target.generation != null &&
              identical(target.client.mux.generation, target.generation) &&
              target.binding.isReady));
  void _retireTarget(CompanionShareTarget target) {
    target._retired = true;
  }

  bool _targetCurrent(CompanionShareTarget target) {
    if (target._retired) return false;
    final existing = _epochs[target.targetEpoch];
    if (existing != null && !identical(existing, target)) {
      _retireTarget(target);
      return false;
    }
    if (existing == null) {
      if (_epochs.length >= 512) {
        _retireTarget(target);
        return false;
      }
      _epochs[target.targetEpoch] = target;
    }
    if (!target.isCurrent || !_targetPure(target)) {
      _retireTarget(target);
      return false;
    }
    return true;
  }

  bool _shareCurrent(CompanionSignalPreview preview, CompanionShareTarget target) {
    if (!identical(preview._gate, this) ||
        !identical(preview.slot.recipientContext, target.recipientContext) ||
        !_slotCurrent(preview.slot) ||
        !_targetCurrent(target)) {
      return false;
    }
    final now = _now();
    return now != null && _slotPure(preview.slot, now) && _targetPure(target);
  }

  CompanionSharePermit? approveShare(
    CompanionSignalPreview preview,
    CompanionShareTarget target, {
    required bool explicitlyConfirmed,
  }) {
    if (!explicitlyConfirmed || !_shareCurrent(preview, target)) return null;
    return CompanionSharePermit._(this, preview, target);
  }

  /// [send] is invoked only for the approved text and exact target. If it awaits
  /// again before writing network bytes, it MUST call stillCurrent at that last
  /// boundary. A late response is rejected; already sent bytes are not retractable.
  Future<CompanionShareResult<T>> dispatch<T>(
    CompanionSharePermit permit,
    Future<T> Function(String approvedText, CompanionShareTarget exactTarget, bool Function() stillCurrent) send,
  ) async {
    if (!identical(permit._gate, this) || permit._used) return const CompanionShareResult(false, null);
    permit._used = true;
    bool current() => _shareCurrent(permit.preview, permit.target);
    if (!current()) return const CompanionShareResult(false, null);
    final target = permit.target;
    if (target is CompanionFullShareTarget) {
      CompanionRecallBinding fresh;
      try {
        fresh = await target.client.readCompanionRecallBinding(target.capabilities, target.binding.bindingId);
      } catch (_) {
        _retireTarget(target);
        return const CompanionShareResult(false, null);
      }
      if (!_sameBinding(fresh, target.binding)) {
        _retireTarget(target);
        return const CompanionShareResult(false, null);
      }
    } else {
      // One explicit async boundary, with the same recheck as the full path.
      await Future<void>.value();
    }
    if (!current()) return const CompanionShareResult(false, null);
    T value;
    try {
      value = await send(permit.preview.text, target, current);
    } catch (_) {
      return const CompanionShareResult(false, null);
    }
    return current() ? CompanionShareResult(true, value) : const CompanionShareResult(false, null);
  }
}

bool _sameBinding(CompanionRecallBinding? a, CompanionRecallBinding b) =>
    a != null &&
    a.isReady &&
    b.isReady &&
    a.bindingId == b.bindingId &&
    a.bridgeEpoch == b.bridgeEpoch &&
    a.recallEpoch == b.recallEpoch &&
    a.storeId == b.storeId &&
    a.memoryRevision == b.memoryRevision &&
    a.sessionId == b.sessionId;

String _template(CompanionSignalV1 signal, String language) {
  final zh = language == 'zh';
  final p = signal.payload;
  return switch (signal.kind) {
    'task.terminal' => switch (p['phase']) {
      'completed' => zh ? '这一轮已完成。' : 'This turn completed.',
      'output_limit' => zh ? '这一轮已到输出上限。' : 'This turn reached its output limit.',
      'stopped' => zh ? '这一轮已停止。' : 'This turn was stopped.',
      'interrupted' => zh ? '这一轮已中断。' : 'This turn was interrupted.',
      'failed' => zh ? '这一轮未能完成。' : 'This turn could not complete.',
      _ => zh ? '这一轮的结果尚不明确。' : 'The turn outcome is unknown.',
    },
    'run.result' => switch (p['result']) {
      'succeeded' when p['runKind'] == 'test' =>
        zh ? '测试命令执行成功，测试数量未知。' : 'The test command succeeded; test counts are unknown.',
      'succeeded' when p['runKind'] == 'build' => zh ? '构建命令执行成功。' : 'The build command succeeded.',
      'succeeded' => zh ? '这条命令执行成功。' : 'This command succeeded.',
      'failed' => zh ? '这条执行命令失败了。' : 'This command failed.',
      'cancelled' => zh ? '这条执行命令已取消。' : 'This command was cancelled.',
      'not_run' => zh ? '这条命令没有执行。' : 'This command was not run.',
      _ => zh ? '这条命令的结果尚不明确。' : 'The command outcome is unknown.',
    },
    'task.approval_waiting' => zh ? '有一个请求等你查看。' : 'A request is waiting for you.',
    'task.approval_cleared' => zh ? '这个请求已经结束。' : 'This request is no longer pending.',
    'app.late_use' => zh ? '你还在这里，想歇一会儿也可以。' : 'You are still here. You can take a break if you want.',
    _ => zh ? '这项状态暂不可用。' : 'This status is unavailable.',
  };
}

/// Future native projection must apply the UNION before constructing metadata.
/// Phone control waivers never remove one of these exclusions. This function
/// grants no collector capability; power and notifications remain unavailable.
bool companionNotificationAllowed(
  String packageId, {
  required Set<String> phoneDenied,
  required Set<String> safetyDenied,
  required Set<String> privatePackages,
  required Set<String> allowlist,
  required String selfPackageId,
  Set<String> systemPackages = const {
    'com.android.settings',
    'com.android.systemui',
    'com.android.permissioncontroller',
    'com.google.android.permissioncontroller',
    'com.android.packageinstaller',
    'com.google.android.packageinstaller',
  },
}) =>
    companionSignalId(packageId) &&
    packageId != selfPackageId &&
    !phoneDenied.contains(packageId) &&
    !safetyDenied.contains(packageId) &&
    !privatePackages.contains(packageId) &&
    !systemPackages.contains(packageId) &&
    allowlist.contains(packageId);

bool _readTargetCurrent(CompanionShareTarget target) {
  if (target._retired) return false;
  bool valid;
  try {
    valid = switch (target) {
      CompanionLightShareTarget() =>
        identical(target.currentKeeper(), target.keeper) &&
            identical(target.currentModelConfiguration(), target.modelConfiguration),
      CompanionFullShareTarget() =>
        identical(target.currentClient(), target.client) &&
            identical(target.currentConnection(), target.connection) &&
            _sameBinding(target.currentBinding(), target.binding),
    };
    valid = identical(target.currentTargetEpoch(), target.targetEpoch) && valid;
  } catch (_) {
    valid = false;
  }
  if (!valid ||
      target._retired ||
      (target is CompanionFullShareTarget &&
          (target.generation == null || !identical(target.client.mux.generation, target.generation)))) {
    target._retired = true;
    return false;
  }
  return true;
}
