import 'dart:async';

import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

PerformanceSnapshot snapshot(DeviceTier tier, {bool hot = false, int sequence = 1}) => PerformanceSnapshot(
  sequence: sequence,
  device: {'tier': tier.name, 'totalMemoryBytes': 8 * 1024 * 1024 * 1024},
  thermal: {'lightweight': hot, 'status': hot ? 2 : 0},
  loaded: true,
  available: true,
);

class FakePerformanceChannel extends PerformanceChannel {
  FakePerformanceChannel(this.initial);
  final Future<PerformanceSnapshot> initial;
  final events = StreamController<PerformanceSnapshot>.broadcast(sync: true);

  @override
  Future<PerformanceSnapshot> snapshot() => initial;
  @override
  Stream<PerformanceSnapshot> get changes => events.stream;
}

/// These tests mount the whole DshApp, whose theme follows the active host's
/// ui.json since #226; the local host's file follows the runtime's platform
/// events, which a widget test has no plugin for. Nothing here reads ui.json:
/// no source, as for a host that can't be read now.
final Override noUiJson = uiConfigSourceBuilderProvider.overrideWithValue((ref, host) => null);
