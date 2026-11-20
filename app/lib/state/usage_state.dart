import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// Token use and context pressure of one session, from DSH projections
/// (`tokenUsage`, `contextPressure`, `contextBreakdown`, `sessionStats`).
class SessionUsage {
  const SessionUsage({
    this.uncachedInput = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
    this.systemTokens,
    this.toolsTokens,
    this.messageTokens,
    this.turns,
    this.llmMs,
    this.toolMs,
  });

  /// Reads the projection values map (missing keys stay null / zero).
  factory SessionUsage.fromProjections(Map<String, Object?> values) {
    Map<String, Object?> map(String key) {
      final v = values[key];
      return v is Map<String, Object?> ? v : const {};
    }

    int? n(Map<String, Object?> m, String key) {
      final v = m[key];
      return v is num ? v.toInt() : null;
    }

    final tokens = map('tokenUsage');
    final pressure = map('contextPressure');
    final breakdown = map('contextBreakdown');
    final stats = map('sessionStats');
    return SessionUsage(
      uncachedInput: n(tokens, 'uncachedInputTokens') ?? 0,
      output: n(tokens, 'outputTokens') ?? 0,
      cacheRead: n(tokens, 'cacheReadTokens') ?? 0,
      cacheWrite: n(tokens, 'cacheWriteTokens') ?? 0,
      pressureTokens: n(pressure, 'pressureTokens'),
      projectedTokens: n(pressure, 'projectedTokens'),
      contextWindow: n(pressure, 'contextWindow'),
      systemTokens: n(breakdown, 'systemTokens'),
      toolsTokens: n(breakdown, 'toolsTokens'),
      messageTokens: n(breakdown, 'messageTokens'),
      turns: n(stats, 'turns'),
      llmMs: n(stats, 'llmMs'),
      toolMs: n(stats, 'toolMs'),
    );
  }

  static const empty = SessionUsage();

  /// Session totals. DSH reports uncached input separately; billed input is
  /// uncached + cache reads + cache writes.
  final int uncachedInput;
  final int output;
  final int cacheRead;
  final int cacheWrite;

  /// Tokens the last request occupied in the context window.
  final int? pressureTokens;

  /// Estimate for the next request (pressure + what was added since).
  final int? projectedTokens;
  final int? contextWindow;
  final int? systemTokens;
  final int? toolsTokens;
  final int? messageTokens;
  final int? turns;
  final int? llmMs;
  final int? toolMs;

  int get input => uncachedInput + cacheRead + cacheWrite;

  /// Share of input served from the provider's prompt cache; null before
  /// the first request.
  double? get cacheHitRate => input == 0 ? null : cacheRead / input;

  /// Estimated next request, or the most recent provider sample as a fallback.
  int? get contextTokens => projectedTokens ?? pressureTokens;

  /// Fraction of the context window in use, when both values are available.
  double? get contextFraction {
    final window = contextWindow;
    final tokens = contextTokens;
    if (window == null || window <= 0 || tokens == null) return null;
    return (tokens / window).clamp(0.0, 1.0);
  }

  bool get hasTokens => input > 0 || output > 0;
}

/// Per-million-token prices of one model route, when they are known.
class TokenPricing {
  const TokenPricing({
    required this.currency,
    required this.inputPerMillion,
    required this.cacheHitPerMillion,
    required this.outputPerMillion,
  });

  final String currency;
  final double inputPerMillion;
  final double cacheHitPerMillion;
  final double outputPerMillion;
}

/// Prices by `provider/model`. Deliberately empty: neither DSH's catalog nor
/// any API the app can reach states what `deepseek-flash` / `deepseek-v4-pro`
/// cost, and a guessed number on a bill is worse than none. The usage sheet
/// shows a cost line only for routes listed here.
const Map<String, TokenPricing> knownPricing = {};

/// Estimated spend of [usage] at [pricing]; cache writes bill as input.
double estimateCost(SessionUsage usage, TokenPricing pricing) =>
    ((usage.uncachedInput + usage.cacheWrite) * pricing.inputPerMillion +
        usage.cacheRead * pricing.cacheHitPerMillion +
        usage.output * pricing.outputPerMillion) /
    1e6;

/// Live [SessionUsage] for one session: seeded from `session/projections`,
/// then kept current by the `session/control` stream (baseline per
/// generation, then per-key frames).
class SessionUsageController extends Notifier<SessionUsage> {
  SessionUsageController(this.sessionId);

  final String sessionId;
  Map<String, Object?> _values = const {};

  /// Seq each key was last set at: an older seed or frame never overwrites it.
  final Map<String, int> _keySeq = {};

  // A control baseline starts a new cut, even on the same client.
  int _seedTicket = 0;
  bool _hasControlCut = false;

  static const _keys = {'tokenUsage', 'contextPressure', 'contextBreakdown', 'sessionStats'};

  @override
  SessionUsage build() {
    final conn = ref.watch(activeConnectionProvider).value;
    _values = const {};
    _keySeq.clear();
    _hasControlCut = false;
    if (conn == null) return SessionUsage.empty;
    final sub = conn.client.watchSessionControl().listen(
      (update) => _onControl(update, conn.client),
      onError: (Object _) {},
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    unawaited(_seed(conn.client));
    return SessionUsage.empty;
  }

  Future<void> _seed(DshClient client) async {
    // Notifier.ref changes when dependencies rebuild; this read belongs to this build.
    final r = ref;
    final ticket = ++_seedTicket;
    // HTTP projections remain usable without a ready WebSocket. Retire the
    // reply if a newer mux generation became ready after this read started,
    // including before the first control baseline reached this controller.
    final readyGeneration = client.mux.lastReadyGenerationNumber;
    try {
      final projections = await client.projections(sessionId);
      if (!r.mounted ||
          ticket != _seedTicket ||
          client.mux.lastReadyGenerationNumber != readyGeneration ||
          projections == null) {
        return;
      }
      _merge(projections);
    } catch (_) {
      // Quiet: the control stream fills it in, and the ring just stays hidden.
    }
  }

  void _onControl(SessionControlUpdate update, DshClient client) {
    if (!ref.mounted) return;
    switch (update) {
      case SessionControlBaseline(:final projections):
        // The initial query may be newer than the first resident baseline.
        // Later cuts must retire reads started under the previous cut.
        if (_hasControlCut) ++_seedTicket;
        _hasControlCut = true;
        final mine = projections[sessionId];
        if (mine != null) {
          _replace(mine);
        } else {
          // The control baseline enumerates resident sessions only. A cold
          // session needs a query, not deletion of its last visible values.
          _keySeq.clear();
          unawaited(_seed(client));
        }
      case SessionControlProjection(:final sessionId, :final key, :final value, :final seq)
          when sessionId == this.sessionId && _keys.contains(key):
        if (seq <= (_keySeq[key] ?? -1)) return;
        _keySeq[key] = seq;
        _values = {..._values, key: value};
        state = SessionUsage.fromProjections(_values);
      default:
        break;
    }
  }

  void _replace(SessionProjections projections) {
    for (final key in _keys) {
      _keySeq[key] = projections.asOfSeq;
    }
    _values = {
      for (final key in _keys)
        if (projections.values.containsKey(key)) key: projections.values[key],
    };
    state = SessionUsage.fromProjections(_values);
  }

  /// A seed: only keys no newer frame has set yet.
  void _merge(SessionProjections projections) {
    final values = {..._values};
    for (final key in _keys) {
      final seen = _keySeq[key];
      if (seen != null && projections.asOfSeq <= seen) continue;
      _keySeq[key] = projections.asOfSeq;
      if (projections.values.containsKey(key)) {
        values[key] = projections.values[key];
      } else {
        values.remove(key);
      }
    }
    _values = values;
    state = SessionUsage.fromProjections(_values);
  }
}

final sessionUsageProvider = NotifierProvider.autoDispose.family<SessionUsageController, SessionUsage, String>(
  SessionUsageController.new,
);
