// Metadata-only local observation. No sensors, input contents, persistence or I/O.
import 'companion_initiative.dart';

class CompanionLateUseTracker {
  int? _lastWall;
  int? _lastMono;
  int? _lastOffset;
  bool _wasResumed = false;
  int? _lastInteraction;
  String? _night;
  int _activeMs = 0;
  bool _faulted = false;

  bool get faulted => _faulted;
  int get activeMs => _activeMs;

  /// Integrates the preceding interval before recording a new real interaction.
  /// An interaction now can never turn the preceding idle time into active use.
  Map<String, Object?>? observe({
    required int wallMs,
    required int monoMs,
    required int offsetMinutes,
    required bool resumed,
    bool interaction = false,
  }) {
    if (_faulted) return null;
    if (wallMs < 0 ||
        wallMs > 8640000000000000 - 3 * 86400000 ||
        monoMs < 0 ||
        monoMs > 9007199254740991 - 86400000 ||
        offsetMinutes < -840 ||
        offsetMinutes > 840) {
      _faulted = true;
      _resetProgress();
      return null;
    }
    final previousWall = _lastWall;
    final previousMono = _lastMono;
    if (previousWall != null && previousMono != null) {
      if (wallMs < previousWall || monoMs < previousMono) {
        _faulted = true;
        _resetProgress();
        return null;
      }
      final drift = ((wallMs - previousWall) - (monoMs - previousMono)).abs();
      if (drift > 1000 || offsetMinutes != _lastOffset) {
        _resetProgress();
      } else if (_wasResumed && _lastInteraction != null) {
        final end = monoMs < _lastInteraction! + 120000 ? monoMs : _lastInteraction! + 120000;
        if (end > previousMono) _integrate(previousWall, previousWall + end - previousMono, offsetMinutes);
      }
    }
    _lastWall = wallMs;
    _lastMono = monoMs;
    _lastOffset = offsetMinutes;
    _wasResumed = resumed;
    final currentNight = companionNightKey(wallMs, offsetMinutes);
    if (currentNight == null || (_night != null && currentNight != _night)) {
      _night = currentNight;
      _activeMs = 0;
    }
    if (!resumed) {
      _lastInteraction = null;
      return null;
    }
    if (interaction) _lastInteraction = monoMs;
    final recent = _lastInteraction != null && monoMs - _lastInteraction! <= 120000;
    if (!recent || currentNight == null || _night != currentNight || _activeMs < 15 * 60000) return null;
    return Map.unmodifiable({
      'nightKey': currentNight,
      'utcOffsetMinutes': offsetMinutes,
      'recentInteraction': true,
      'activeMinutesBucket': '15plus',
    });
  }

  void _resetProgress() {
    _night = null;
    _activeMs = 0;
    _lastInteraction = null;
  }

  void _integrate(int startWall, int endWall, int offset) {
    final local = DateTime.fromMillisecondsSinceEpoch(startWall + offset * 60000, isUtc: true);
    var nightStart = DateTime.utc(local.year, local.month, local.day, 23).millisecondsSinceEpoch - offset * 60000;
    if (local.hour < 7) nightStart -= 86400000;
    final nightEnd = nightStart + 8 * 60 * 60000;
    final start = startWall > nightStart ? startWall : nightStart;
    final end = endWall < nightEnd ? endWall : nightEnd;
    if (end <= start) return;
    final key = companionNightKey(nightStart, offset)!;
    if (_night != key) {
      _night = key;
      _activeMs = 0;
    }
    _activeMs += end - start;
    // The wire only communicates the reached threshold; bound retained state.
    if (_activeMs > 15 * 60000) _activeMs = 15 * 60000;
  }
}
