// What the on-device runtime costs, shown where the
// person decides whether to install it (first run, 安装本机运行环境).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/diagnostics_channel.dart';
import 'runtime_bridge.dart';

extension RuntimeMissing on RuntimeStatus {
  /// Android reported no runtime on this phone: never installed, or
  /// uninstalled. Every real report names the bundled runtime; a status
  /// without one is no report at all (no native side: tests, other
  /// platforms) and counts as unknown, not missing.
  bool get runtimeMissing => phase == RuntimePhase.notInstalled && bundledVersion != null;
}

/// The phone's memory and free storage, and the bundled runtime's unpacked
/// size; any of them null when Android did not say.
class LocalFootprint {
  const LocalFootprint({this.totalMemoryMb, this.freeStorageMb, this.unpackedMb});

  /// `ActivityManager.MemoryInfo.totalMem`, MiB.
  final int? totalMemoryMb;

  /// Free space where the runtime unpacks (app files dir), MiB.
  final int? freeStorageMb;

  /// The rootfs once unpacked (`manifest.json` `uncompressedBytes`), MiB.
  final int? unpackedMb;

  /// Below this the remote host is the suggested way. Phones report less
  /// than their rated memory: a 4 GB phone reads about 3.7 GB, a 6 GB one
  /// about 5.5 GB.
  static const lowMemoryMb = 5 * 1024;

  /// What the engine (proot + Node + DSH) takes while it runs, MiB: its peak,
  /// rounded. PSS from `/proc/<pid>/smaps_rollup` on the x86_64 emulator (DSH
  /// 0.2.1-rc.2): node 275–306 MB for the first minute or so after start,
  /// about 185 MB once settled and through a turn without a model; proot
  /// about 1 MB. A real turn's tool processes come on top.
  static const engineMemoryMb = 300;

  /// What the installer insists on (`RuntimeInstaller.checkFreeSpace`:
  /// unpacked size + 15%).
  int? get requiredStorageMb => unpackedMb == null ? null : (unpackedMb! * 115 + 99) ~/ 100;

  /// [requiredStorageMb] rounded up to 50, for the 「存储空间不足」 line.
  int? get requiredRoundedMb => requiredStorageMb == null ? null : (requiredStorageMb! + 49) ~/ 50 * 50;

  bool get lowMemory => totalMemoryMb != null && totalMemoryMb! < lowMemoryMb;

  bool get lowStorage => freeStorageMb != null && requiredStorageMb != null && freeStorageMb! < requiredStorageMb!;

  /// Point to the remote host first: this phone is short of memory or room.
  bool get suggestRemote => lowMemory || lowStorage;

  /// A size as people read it: to the nearest 50 MB.
  static int round(int mb) => ((mb + 25) ~/ 50) * 50;
}

/// Read once per launch from the diagnostics channel (no native side in
/// tests or off Android: every figure null).
final localFootprintProvider = FutureProvider<LocalFootprint>((ref) async {
  final info = await ref.watch(diagnosticsChannelProvider).info();
  int? whole(Object? v) => v is num && v >= 0 ? v.round() : null;
  final unpacked = info.manifest['uncompressedBytes'];
  final memory = whole(info.device['memoryMb']);
  return LocalFootprint(
    totalMemoryMb: memory == 0 ? null : memory,
    freeStorageMb: whole(info.device['freeStorageMb']),
    unpackedMb: unpacked is num && unpacked > 0 ? (unpacked / (1024 * 1024)).round() : null,
  );
});
