// A ticking elapsed-time leaf, so live timers repaint a few glyphs once a
// second instead of the list or the screen around them.

import 'dart:async';

import 'package:flutter/widgets.dart';

/// The wall clock live timers read (tests freeze it).
DateTime Function() runClock = DateTime.now;

/// Rebuilds only [builder]'s subtree once per elapsed second since [since]
/// (a Host timestamp; [skew] is device minus Host clock). Stops ticking when
/// removed, backgrounded, or disabled by TickerMode; never ticks when [since] is null.
class LiveElapsed extends StatefulWidget {
  const LiveElapsed({super.key, required this.since, required this.builder, this.skew = Duration.zero});

  final DateTime? since;
  final Duration skew;
  final Widget Function(BuildContext context, Duration? elapsed) builder;

  /// Elapsed time since [since] on the Host clock, never negative.
  static Duration elapsedSince(DateTime since, Duration skew) {
    final elapsed = runClock().subtract(skew).difference(since);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  @override
  State<LiveElapsed> createState() => _LiveElapsedState();
}

class _LiveElapsedState extends State<LiveElapsed> with WidgetsBindingObserver {
  Timer? _timer;
  bool _tickerEnabled = true;
  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedule();
    if (_foreground && _tickerEnabled) setState(() {});
  }

  @override
  void didUpdateWidget(LiveElapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.since != widget.since || oldWidget.skew != widget.skew) {
      _schedule();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// Next tick on the next whole second of elapsed time.
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final since = widget.since;
    if (since == null || !_tickerEnabled || !_foreground) return;
    final ms = LiveElapsed.elapsedSince(since, widget.skew).inMilliseconds;
    _timer = Timer(Duration(milliseconds: 1000 - ms % 1000 + 5), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    return widget.builder(context, since == null ? null : LiveElapsed.elapsedSince(since, widget.skew));
  }
}
