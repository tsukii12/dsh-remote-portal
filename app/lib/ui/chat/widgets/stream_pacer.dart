import 'dart:math' as math;

/// Lets text that arrives in lumps come out at a steady pace: how many characters
/// to show, given how many have arrived.
///
/// It follows the arrival rate (smoothed), and speeds up when it falls behind, so
/// the backlog stays under [maxLag] and a fast model never leaves it trailing.
class StreamPacer {
  StreamPacer({int shown = 0}) : _shown = shown.toDouble(), _arrived = shown;

  /// The longest the text shown may trail what arrived.
  static const maxLag = 0.35;

  /// Never slower than this while something is waiting, or a slow model's last
  /// few characters would crawl.
  static const minRate = 24.0;

  /// How quickly the estimate follows the arrival rate.
  static const _rateSeconds = 0.8;

  double _shown;
  double _rate = minRate * 2;
  int _arrived;
  double _sinceArrival = 0;

  /// Characters to show now.
  int get shown => _shown.floor();

  /// Whether [target] characters are all out.
  bool caughtUp(int target) => _shown >= target;

  /// The text was replaced rather than extended: starts over at [shown].
  void reset(int shown) {
    _shown = shown.toDouble();
    _arrived = shown;
    _sinceArrival = 0;
  }

  /// Advances by [seconds] toward [target] characters.
  void advance(double seconds, int target) {
    if (seconds <= 0) return;
    _sinceArrival += seconds;
    if (target > _arrived) {
      final observed = (target - _arrived) / _sinceArrival;
      final blend = 1 - math.exp(-_sinceArrival / _rateSeconds);
      _rate += (observed - _rate) * blend;
      _arrived = target;
      _sinceArrival = 0;
    } else if (target < _arrived) {
      _arrived = target;
    }
    final backlog = target - _shown;
    if (backlog <= 0) {
      _shown = math.min(_shown, target.toDouble());
      return;
    }
    final speed = math.max(math.max(_rate, minRate), backlog / maxLag);
    _shown = math.min(_shown + speed * seconds, target.toDouble());
  }
}
