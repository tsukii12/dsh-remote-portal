// Synchronous elapsed time for the installation owner. Android's Dart
// Stopwatch uses CLOCK_MONOTONIC, which stops during deep sleep. BOOTTIME is
// the clock used by Android SystemClock.elapsedRealtime and includes sleep.
import 'dart:ffi';
import 'dart:io';

import 'companion_initiative.dart';

/// Samples one wall instant between two elapsed reads. A process suspended
/// between those reads must resample rather than manufacture wall-clock drift.
/// Only sampling duration is retried; wall/elapsed deltas across observations
/// remain subject to the controller's unchanged 1000 ms jump check.
final class CompanionClockSampler {
  CompanionClockSampler({required int Function() elapsedMilliseconds, DateTime Function()? wallNow})
    : _elapsed = elapsedMilliseconds,
      _wallNow = wallNow ?? DateTime.now;
  final int Function() _elapsed;
  final DateTime Function() _wallNow;
  bool _failed = false;

  CompanionInitiativeClock read() {
    if (!_failed) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final before = _elapsed();
          if (before < 0 || before > 9007199254740991) break;
          final wall = _wallNow();
          final after = _elapsed();
          if (after < before || after > 9007199254740991) break;
          if (after - before > 100) continue;
          return CompanionInitiativeClock(
            wallMs: wall.millisecondsSinceEpoch,
            monoMs: before + (after - before) ~/ 2,
            offsetMinutes: wall.timeZoneOffset.inMinutes,
          );
        } on Object {
          break;
        }
      }
      _failed = true;
    }
    return const CompanionInitiativeClock(wallMs: 0, monoMs: -1);
  }
}

/// A clock failure is sticky. -1 is an invalid controller stamp, never a
/// substitute wall-clock estimate or a fresh epoch after a failed read.
final class CompanionElapsedClock {
  CompanionElapsedClock({bool? android, int Function()? bootTimeMilliseconds, int Function()? stopwatchMilliseconds}) {
    if (android ?? Platform.isAndroid) {
      try {
        _read = bootTimeMilliseconds ?? CompanionBootTimeClock.open().readMilliseconds;
      } on Object {
        _read = () => -1;
      }
    } else {
      final watch = Stopwatch()..start();
      _read = stopwatchMilliseconds ?? () => watch.elapsedMilliseconds;
    }
  }

  late final int Function() _read;
  bool _failed = false;
  int _last = 0;
  int readMilliseconds() {
    if (_failed) return -1;
    try {
      final value = _read();
      if (value >= _last && value <= 9007199254740991) return _last = value;
    } on Object {
      // An unavailable native symbol/read is a closed clock, not Stopwatch.
    }
    _failed = true;
    return -1;
  }
}

final class _Timespec64 extends Struct {
  @Int64()
  external int seconds;
  @Int64()
  external int nanoseconds;
}

/// The shipped Android arm64/x64 ABIs have a 64-bit time_t and long. The same
/// Linux ABIs allow a native smoke check on the test host; desktop owners still
/// select Stopwatch. Unsupported ABIs fail before native memory is allocated.
final class CompanionBootTimeClock {
  CompanionBootTimeClock._(DynamicLibrary libc)
    : _getTime = libc
          .lookupFunction<Int32 Function(Int32, Pointer<_Timespec64>), int Function(int, Pointer<_Timespec64>)>(
            'clock_gettime',
          ),
      _calloc = libc.lookupFunction<Pointer<Void> Function(UintPtr, UintPtr), Pointer<Void> Function(int, int)>(
        'calloc',
      ),
      _free = libc.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

  static bool supportsAbi(Abi abi) =>
      const {Abi.androidArm64, Abi.androidX64, Abi.linuxArm64, Abi.linuxX64}.contains(abi);

  static CompanionBootTimeClock open() {
    if (!supportsAbi(Abi.current())) throw UnsupportedError('Unsupported BOOTTIME ABI');
    return CompanionBootTimeClock._(Platform.isAndroid ? DynamicLibrary.open('libc.so') : DynamicLibrary.process());
  }

  final int Function(int, Pointer<_Timespec64>) _getTime;
  final Pointer<Void> Function(int, int) _calloc;
  final void Function(Pointer<Void>) _free;

  int readMilliseconds() {
    // Core dart:ffi plus libc allocation: no undeclared transitive package.
    // Lookups are retained above; each small buffer is released even on error.
    final memory = _calloc(1, sizeOf<_Timespec64>());
    if (memory == nullptr) throw StateError('BOOTTIME allocation failed');
    try {
      final time = memory.cast<_Timespec64>();
      if (_getTime(7, time) != 0) throw StateError('BOOTTIME read failed');
      final seconds = time.ref.seconds, nanos = time.ref.nanoseconds;
      if (seconds < 0 || seconds > 9007199254740 || nanos < 0 || nanos >= 1000000000) {
        throw StateError('Invalid BOOTTIME value');
      }
      final milliseconds = seconds * 1000 + nanos ~/ 1000000;
      if (milliseconds > 9007199254740991) throw StateError('BOOTTIME value overflow');
      return milliseconds;
    } finally {
      _free(memory);
    }
  }
}
