import 'package:dsh_app/performance/performance_state.dart';

/// A performance channel with no device behind it: it answers at once that
/// nothing is available, so no test waits on (or leaves a timer for) a
/// platform reply. Tests about the channel override the provider themselves.
class QuietPerformanceChannel extends PerformanceChannel {
  @override
  Future<PerformanceSnapshot> snapshot() => Future.value(const PerformanceSnapshot(loaded: true));
}
