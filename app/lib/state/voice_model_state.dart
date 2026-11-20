// The on-device voice model (SenseVoice, run by the engine's voice-input
// bundle): status, download, cancel, delete, and the first-run download the
// person asked for during onboarding.
//
// The model lives in the on-device engine only (its rootfs): this controller
// talks to the local connection, never to a remote host. A download:
//   1. checks free space, then fetches the files from a mainland mirror into
//      the engine's model cache (resumable; voice/voice_model_download.dart);
//   2. switches the bundle on (applies live) and asks the engine to prepare,
//      which verifies the cached files and loads the model;
//   3. falls back to the engine's own download (Hugging Face) when the mirror
//      fails, so a reachable Hugging Face still works.
// A started download is remembered: when the app is killed it goes on the next
// time the engine is up (finished files and partial ones are kept).

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/diagnostics_channel.dart';
import '../share_code/guest_fs.dart';
import '../voice/voice_model_assets.dart';
import '../voice/voice_model_download.dart';
import 'connection_state.dart';

enum VoiceModelStatus {
  /// The on-device engine is not connected yet (starting, stopped, never set up).
  waiting,

  /// This engine has no voice-input bundle.
  unsupported,

  /// Not downloaded (or only partly).
  absent,

  /// Files are coming in.
  downloading,

  /// The engine checks and loads the files.
  preparing,
  ready,
  failed,
}

enum VoiceModelFailure { network, timeout, certificate, server, integrity, storage, engine, unknown }

/// What the person sees about the model.
@immutable
class VoiceModelState {
  const VoiceModelState({
    this.status = VoiceModelStatus.waiting,
    this.doneBytes = 0,
    this.totalBytes = voiceModelDefaultBytes,
    this.failure,
    this.neededBytes,
    this.wanted = false,
  });

  final VoiceModelStatus status;

  /// Bytes in place, of [totalBytes].
  final int doneBytes;
  final int totalBytes;

  final VoiceModelFailure? failure;

  /// For [VoiceModelFailure.storage]: free space the download needs.
  final int? neededBytes;

  /// A download was asked for and is not finished: it goes on by itself.
  final bool wanted;

  bool get busy => status == VoiceModelStatus.downloading || status == VoiceModelStatus.preparing;

  /// 0–1; null while the amount is unknown.
  double? get fraction => totalBytes <= 0 ? null : (doneBytes / totalBytes).clamp(0.0, 1.0);

  VoiceModelState copyWith({
    VoiceModelStatus? status,
    int? doneBytes,
    int? totalBytes,
    VoiceModelFailure? failure,
    bool clearFailure = false,
    int? neededBytes,
    bool? wanted,
  }) => VoiceModelState(
    status: status ?? this.status,
    doneBytes: doneBytes ?? this.doneBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    failure: clearFailure ? null : (failure ?? this.failure),
    neededBytes: clearFailure ? null : (neededBytes ?? this.neededBytes),
    wanted: wanted ?? this.wanted,
  );
}

/// SenseVoice INT8 + tokens + Silero VAD in 0.2.1-rc.2 (the lock in the rootfs wins).
const voiceModelDefaultBytes = 239233841 + 315894 + 1807522;

/// Room kept free on top of the files themselves.
const voiceModelSpareBytes = 100 * 1024 * 1024;


/// Moments the shell turns into a short message.
enum VoiceModelEventKind { started, ready, failed }

class VoiceModelEvent {
  const VoiceModelEvent(
    this.kind, {
    this.bytes = 0,
    this.resumed = false,
    this.failure,
    this.neededBytes,
    this.again = false,
  });
  final VoiceModelEventKind kind;

  /// [VoiceModelEventKind.started]: bytes still to download.
  final int bytes;

  /// [VoiceModelEventKind.started]: part of it was already there.
  final bool resumed;
  final VoiceModelFailure? failure;
  final int? neededBytes;

  /// [VoiceModelEventKind.failed] of a 重新下载: the model in place was kept,
  /// and 重试 asks for the whole model again.
  final bool again;
}

/// A running file download (seam for tests).
class VoiceDownloadRun {
  const VoiceDownloadRun({required this.progress, required this.done, required this.cancel});
  final Stream<int> progress;
  final Future<void> done;
  final void Function() cancel;
}

/// The phone side: the rootfs, free space, the network kind, the download
/// isolate and the engine notification's progress line.
abstract class VoiceModelPlatform {
  Future<VoiceModelFiles?> files();
  Future<int?> freeBytes();

  /// Mobile data (counted), not Wi-Fi or Ethernet.
  Future<bool> metered();
  Future<VoiceDownloadRun> download(List<VoiceDownloadJob> jobs);

  /// The engine notification's line: [text] with a bar ([progress] 0–100,
  /// -1 indeterminate, null none); null [text] restores the usual line.
  Future<void> notice(String? text, {int? progress});
}

class DeviceVoiceModelPlatform implements VoiceModelPlatform {
  static const _runtime = MethodChannel('dsh/runtime');

  @override
  Future<VoiceModelFiles?> files() async {
    final fs = await GuestFs.local();
    return fs == null ? null : VoiceModelFiles(fs.root);
  }

  @override
  Future<int?> freeBytes() async {
    final mb = (await const DiagnosticsChannel().info()).device['freeStorageMb'];
    return mb is int ? mb * 1024 * 1024 : null;
  }

  @override
  Future<bool> metered() async {
    try {
      final kinds = await Connectivity().checkConnectivity();
      return kinds.contains(ConnectivityResult.mobile) &&
          !kinds.contains(ConnectivityResult.wifi) &&
          !kinds.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<VoiceDownloadRun> download(List<VoiceDownloadJob> jobs) async {
    final task = await VoiceDownloadTask.start(jobs);
    return VoiceDownloadRun(progress: task.progress, done: task.done, cancel: task.cancel);
  }

  @override
  Future<void> notice(String? text, {int? progress}) async {
    try {
      await _runtime.invokeMethod<void>('voiceModelLine', {'text': text, 'progress': progress});
    } on MissingPluginException {
      // Tests, other platforms.
    } on PlatformException {
      // An older native side: the in-app status is still there.
    }
  }
}

final voiceModelPlatformProvider = Provider<VoiceModelPlatform>((ref) => DeviceVoiceModelPlatform());

/// Texts for the engine notification (set by the shell, which knows the language).
class VoiceModelNoticeText {
  const VoiceModelNoticeText({required this.downloading, required this.preparing, required this.ready, required this.failed});
  final String Function(int percent) downloading;
  final String preparing;
  final String ready;
  final String failed;
}

/// The engine notification's voice line, posted at most once per
/// [VoiceModelController.noticeEvery]: Android drops an app's updates past
/// five a second, and the download reports every quarter second. Lines that
/// come in between wait, and only the latest of them goes when the time is
/// up (the notification shows the latest anyway). The line already up is not
/// posted again.
class _NoticeGate {
  _NoticeGate(this._post);

  final void Function(String? text, int? progress) _post;

  /// The line up now; null before the first post.
  (String?, int?)? _shown;
  (String?, int?)? _next;
  Timer? _window;

  void add(String? text, int? progress) {
    final line = (text, progress);
    if (_window != null) {
      _next = line;
    } else if (line != _shown) {
      _send(line);
    }
  }

  void _send((String?, int?) line) {
    _shown = line;
    _post(line.$1, line.$2);
    final every = VoiceModelController.noticeEvery;
    if (every > Duration.zero) _window = Timer(every, _flush);
  }

  void _flush() {
    _window = null;
    final line = _next;
    _next = null;
    if (line != null && line != _shown) _send(line);
  }

  void dispose() {
    _window?.cancel();
    _window = null;
  }
}

class VoiceModelController extends Notifier<VoiceModelState> {
  /// Set by onboarding: the person chose voice input (and saw the size).
  static const onboardingKey = 'onboarding_wants_voice';

  /// The onboarding choice was acted on once; later deletes stay deleted.
  static const onboardingHandledKey = 'voice_model_onboarding_handled';

  /// A download was asked for and has not finished.
  static const wantedKey = 'voice_model_wanted';

  /// How often the engine's preparation is read while it runs.
  @visibleForTesting
  static Duration pollEvery = const Duration(milliseconds: 700);

  /// The engine's own download gives up after this long without a byte (its
  /// own deadline is an hour).
  @visibleForTesting
  static Duration stall = const Duration(seconds: 60);

  /// The engine notification's line changes at most once this often (two a
  /// second, under Android's five).
  @visibleForTesting
  static Duration noticeEvery = const Duration(milliseconds: 500);

  final _events = StreamController<VoiceModelEvent>.broadcast();
  Stream<VoiceModelEvent> get events => _events.stream;

  /// Notification texts; null keeps the engine notification as it is.
  VoiceModelNoticeText? noticeText;

  DshClient? _client;
  int _run = 0;
  VoiceDownloadRun? _download;

  /// Every mirror download that may still write: each from before its
  /// isolate is spawned until it reports that it ended (however it ended). A
  /// newer one never stands for an older one: a cancelled run can return
  /// while its download is still stopping (the handle came back after the
  /// cancel), and a retry starts the next (CR-7881a22 S1).
  final _writers = <Completer<void>>{};

  /// How long [cancel] waits for the download to stop writing. Running out
  /// is not a stop: [downloadStopping] stays true and [delete] keeps the files.
  @visibleForTesting
  static Duration downloadStopWait = const Duration(seconds: 10);

  Timer? _poll;
  bool _cancelled = false;
  bool _foreground = true;

  /// 重新下载 is bringing its copy into [VoiceModelPaths.staging]; the model in
  /// place, and what was shown about it ([_kept]), stay until the swap.
  bool _replacing = false;
  VoiceModelState _kept = const VoiceModelState();

  /// The run in flight (download, then the engine's part) and its id: it is
  /// live while its id is still [_run]; a cancel or a new engine makes it stale.
  Future<void>? _running;
  int _runningId = 0;
  bool _inPrepare = false;
  late final _gate = _NoticeGate((text, progress) => unawaited(_platform.notice(text, progress: progress)));
  late Future<void> _loaded;

  VoiceModelPlatform get _platform => ref.read(voiceModelPlatformProvider);

  @override
  VoiceModelState build() {
    ref.onDispose(() {
      _run++;
      _poll?.cancel();
      _download?.cancel();
      _gate.dispose();
      unawaited(_events.close());
    });
    ref.listen(localConnectionProvider, (_, next) => _connected(next.value?.client), fireImmediately: false);
    _loaded = _load();
    scheduleMicrotask(() => _connected(ref.read(localConnectionProvider).value?.client));
    return const VoiceModelState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var wanted = prefs.getBool(wantedKey) ?? false;
      if (prefs.getBool(onboardingKey) == true && prefs.getBool(onboardingHandledKey) != true) {
        // The person chose voice input during setup (the size was shown there).
        await prefs.setBool(onboardingHandledKey, true);
        await prefs.setBool(wantedKey, true);
        wanted = true;
      }
      if (ref.mounted && wanted != state.wanted) state = state.copyWith(wanted: wanted);
    } catch (_) {
      // Unreadable preferences: nothing resumes by itself this run.
    }
    // A 重新下载 cut short by a kill: the model in place was never touched,
    // and its copy is not needed. (Every run waits for this load first.)
    await _dropStaging();
  }

  Future<void> _setWanted(bool wanted) async {
    if (ref.mounted) state = state.copyWith(wanted: wanted);
    try {
      await (await SharedPreferences.getInstance()).setBool(wantedKey, wanted);
    } catch (_) {}
  }

  void _connected(DshClient? client) {
    if (!ref.mounted || identical(client, _client)) return;
    // The engine's part talks to one engine: a new one (or none) retires it.
    // A file download needs no engine and goes on.
    if (_inPrepare || (_poll?.isActive ?? false)) _run++;
    _client = client;
    if (client == null) {
      // The engine went away: a file download goes on (it needs no engine);
      // the engine's part waits for it to come back. Nothing on disk is lost.
      _poll?.cancel();
      if (_download == null) state = state.copyWith(status: VoiceModelStatus.waiting);
      return;
    }
    unawaited(refresh());
  }

  /// Re-reads the model's state (settings page, app back on screen).
  Future<void> refresh() async {
    await _loaded;
    final client = _client;
    if (!ref.mounted) return;
    if (client == null) {
      if (!state.busy) state = state.copyWith(status: VoiceModelStatus.waiting);
      return;
    }
    // A live run or poll owns the state.
    if (_owned) return;
    final files = await _platform.files();
    final assets = files?.assets();
    if (!ref.mounted || !identical(client, _client)) return;
    if (files == null || assets == null) {
      state = state.copyWith(status: VoiceModelStatus.unsupported);
      return;
    }
    final total = _total(assets);
    SpeechProviderView? provider;
    try {
      provider = await _provider(client);
    } catch (_) {
      provider = null;
    }
    if (!ref.mounted || !identical(client, _client) || _owned) return;
    final present = files.presentBytes(assets);
    if (provider != null && provider.usable) {
      _settledReady(total);
      return;
    }
    if (provider != null && _preparing(provider.phase)) {
      _show(provider, files, assets);
      _follow(client, ++_run, files, assets, announce: false);
      return;
    }
    final failed = state.status == VoiceModelStatus.failed;
    state = state.copyWith(
      status: failed ? VoiceModelStatus.failed : VoiceModelStatus.absent,
      doneBytes: present,
      totalBytes: total,
    );
    if (state.wanted && !_cancelled && !failed) unawaited(_start(announce: true));
  }

  /// Download (or go on with) the model. The settings page asks about mobile data first.
  Future<void> download() async {
    await _loaded;
    _cancelled = false;
    await _setWanted(true);
    if (_client == null) {
      if (ref.mounted) state = state.copyWith(status: VoiceModelStatus.waiting, clearFailure: true);
      return;
    }
    await _start(announce: true);
  }

  /// Whether a download now would use mobile data.
  Future<bool> metered() => _platform.metered();

  /// A file download has not said yet that it stopped writing (after a
  /// [cancel]: the wait ran out, or it was still being started), the latest
  /// or any before it.
  bool get downloadStopping => _writers.any((w) => !w.isCompleted);

  /// Stops a download; finished and partial files stay for later. Returns
  /// once every file download has stopped writing, or after
  /// [downloadStopWait] with [downloadStopping] still true.
  Future<void> cancel() async {
    final replacing = _replacing;
    _replacing = false;
    _cancelled = true;
    final run = ++_run;
    _poll?.cancel();
    _download?.cancel();
    _download = null;
    // Every download that may still write, not only the latest: an older one
    // is stopped by its own (stale) run once its handle is back. One started
    // after this cancel is not waited for here ([delete] still checks it).
    final writing = [
      for (final w in _writers)
        if (!w.isCompleted) w.future,
    ];
    await _setWanted(false);
    final client = _client;
    // 重新下载 never touched the engine: the model it has loaded stays.
    if (client != null && !replacing) {
      try {
        await client.cancelSpeechPreparation(voiceModelProviderId, timeout: const Duration(seconds: 20));
      } catch (_) {}
    }
    // The cancel can reach the download mid-file (a last chunk, the rename):
    // what comes next (a delete) must not be undone by a file landing after it.
    if (writing.isNotEmpty) {
      await Future.wait(writing).timeout(downloadStopWait, onTimeout: () => const <void>[]);
    }
    // The 重新下载 copy goes only once nothing may still write into it: a
    // stop not reported yet leaves it where it is (a later 重新下载 or delete
    // removes it after the same check, the next start in any case).
    if (replacing && !downloadStopping) await _dropStaging();
    if (!_alive(run)) return;
    _line(null);
    state = replacing
        ? _kept.copyWith(wanted: false)
        : state.copyWith(status: _client == null ? VoiceModelStatus.waiting : VoiceModelStatus.absent, clearFailure: true);
    unawaited(refresh());
  }

  /// Removes the model: the bundle goes off first (the engine lets go of the
  /// files), then the files. Voice input falls back to the phone's service.
  /// False when nothing was deleted: the download has not said it stopped
  /// writing ([downloadStopping]; a file could land after the delete), the
  /// engine did not switch the bundle off (its recognizer would go on as
  /// "ready" on files that are gone, their space held until it exits), or the
  /// files could not be removed. Each can be tried again.
  Future<bool> delete() async {
    await cancel();
    // Checked before anything changes: the engine and the files stay as they are.
    if (downloadStopping) return false;
    final client = _client;
    if (client != null) {
      try {
        final result = await client.setBundleEnabled(voiceInputBundle, false);
        if (result.application != PluginApplication.applied) return false;
      } catch (_) {
        return false;
      }
    }
    var ok = true;
    try {
      await (await _platform.files())?.delete();
    } catch (_) {
      ok = false;
    }
    if (ref.mounted) {
      state = state.copyWith(status: VoiceModelStatus.absent, doneBytes: 0, clearFailure: true);
      unawaited(refresh());
    }
    return ok;
  }

  /// Downloads the whole model again. The new files come into
  /// [VoiceModelPaths.staging] and take the old ones' place only once every
  /// one is in and checked (size and SHA-256 against the engine's lock), so a
  /// cancel or a failure on the way leaves the model as it was, still in use.
  /// A file the app has no mirror for only the engine can fetch, into its own
  /// cache: then, as before, delete and download.
  Future<void> redownload() async {
    await _loaded;
    if (!ref.mounted) return;
    final files = await _platform.files();
    final assets = files?.assets();
    if (!ref.mounted) return;
    if (_client == null ||
        files == null ||
        assets == null ||
        !files.complete(assets) ||
        assets.any((a) => a.mirrors.isEmpty)) {
      if (!await delete()) return;
      await download();
      return;
    }
    _cancelled = false;
    await _exclusive((run) => _replaceRun(run, files, assets));
  }

  /// The app is on screen again: a finished line leaves the notification.
  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground && !state.busy) _line(null);
    if (foreground) unawaited(refresh());
  }

  // ── the run ─────────────────────────────────────────────────────────────

  bool get _owned => (_running != null && _runningId == _run) || _download != null || (_poll?.isActive ?? false);

  Future<void> _start({required bool announce}) => _exclusive((run) => _startRun(run, announce: announce));

  /// [body] as the one run in flight, under a new run id; nothing when a run
  /// is live already.
  Future<void> _exclusive(Future<void> Function(int run) body) async {
    if (_client == null) return;
    if (_running case final running?) {
      if (_runningId == _run) return;
      // A cancelled run is winding down: start once it is gone.
      await running;
      if (_running != null || _client == null) return;
    }
    if (_download != null || (_poll?.isActive ?? false)) return;
    final run = ++_run;
    _runningId = run;
    final future = body(run);
    _running = future;
    try {
      await future;
    } finally {
      if (identical(_running, future)) _running = null;
    }
  }

  Future<void> _startRun(int run, {required bool announce}) async {
    _poll?.cancel();
    // Busy at once: a second caller (refresh racing download) stops above.
    state = state.copyWith(status: VoiceModelStatus.downloading, clearFailure: true);
    final files = await _platform.files();
    final assets = files?.assets();
    if (!_alive(run)) return;
    if (files == null || assets == null) {
      state = state.copyWith(status: VoiceModelStatus.unsupported);
      return;
    }
    final total = _total(assets);
    final present = files.presentBytes(assets);
    state = state.copyWith(doneBytes: present, totalBytes: total);
    _notice(VoiceModelStatus.downloading);

    // Two questions: how much still has to come over the network (space, the
    // started notice), and whether a file still has to be checked and given
    // its final name. A .part already at full length (the app died before its
    // check) needs no network, but only the downloader publishes it: the
    // engine looks at final names only and would fetch that file again.
    final missing = total - present;
    if (missing > 0) {
      final free = await _platform.freeBytes();
      if (!_alive(run)) return;
      if (free != null && free < missing + voiceModelSpareBytes) {
        _fail(VoiceModelFailure.storage, neededBytes: missing + voiceModelSpareBytes);
        return;
      }
      if (announce) _events.add(VoiceModelEvent(VoiceModelEventKind.started, bytes: missing, resumed: present > 0));
    }
    if (!files.complete(assets) && assets.every((a) => a.mirrors.isNotEmpty)) {
      final failure = await _fetch(run, [
        for (final a in assets)
          VoiceDownloadJob(urls: a.mirrors, path: files.host(a.guestPath).path, bytes: a.bytes, sha256: a.sha256),
      ]);
      if (!_alive(run)) return;
      if (failure == VoiceModelFailure.storage) {
        _fail(VoiceModelFailure.storage, neededBytes: missing + voiceModelSpareBytes);
        return;
      }
      // Other mirror failures: the engine tries its own sources below.
    }
    final client = _client;
    if (client == null) {
      // Files are in; the engine part runs when it is back (still wanted).
      state = state.copyWith(status: VoiceModelStatus.waiting, doneBytes: files.presentBytes(assets));
      return;
    }
    _inPrepare = true;
    try {
      await _prepare(run, client, files, assets);
    } finally {
      _inPrepare = false;
    }
  }

  /// 重新下载: every file from its mirror into staging, checked, then the
  /// swap and the engine's part as after any download.
  Future<void> _replaceRun(int run, VoiceModelFiles files, List<VoiceModelAsset> assets) async {
    final total = _total(assets);
    _kept = state;
    _replacing = true;
    try {
      state = state.copyWith(status: VoiceModelStatus.downloading, doneBytes: 0, totalBytes: total, clearFailure: true);
      _notice(VoiceModelStatus.downloading);
      // A download cancelled earlier may not have said yet that it stopped,
      // and may be writing into staging: nothing there is touched, and no new
      // copy starts, until it has.
      if (!await _writersStopped()) {
        if (_alive(run)) _keep(VoiceModelFailure.unknown);
        return;
      }
      if (!_alive(run)) return;
      await _dropStaging();
      final free = await _platform.freeBytes();
      if (!_alive(run)) return;
      // The old files stay until the swap: room for a second copy.
      if (free != null && free < total + voiceModelSpareBytes) {
        _keep(VoiceModelFailure.storage, neededBytes: total + voiceModelSpareBytes);
        return;
      }
      _events.add(VoiceModelEvent(VoiceModelEventKind.started, bytes: total));
      final failure = await _fetch(run, [
        for (final a in assets)
          VoiceDownloadJob(urls: a.mirrors, path: files.staged(a).path, bytes: a.bytes, sha256: a.sha256),
      ]);
      if (!_alive(run)) return;
      if (failure != null) {
        if (!downloadStopping) await _dropStaging();
        if (_alive(run)) _keep(failure);
        return;
      }
      // Every file is in and matches the lock: they take the old ones' place.
      try {
        await files.promoteStaged(assets);
      } catch (_) {
        if (!downloadStopping) await _dropStaging();
        if (_alive(run)) _keep(VoiceModelFailure.unknown);
        return;
      }
      _replacing = false;
      if (!_alive(run)) return;
      final client = _client;
      if (client == null) {
        state = state.copyWith(status: VoiceModelStatus.waiting, doneBytes: total);
        return;
      }
      _inPrepare = true;
      try {
        await _prepare(run, client, files, assets);
      } finally {
        _inPrepare = false;
      }
    } finally {
      _replacing = false;
    }
  }

  /// 重新下载 did not get its copy in: the model in place is still the one
  /// in use, shown as it was. Says why; 重试 asks for the whole model again.
  void _keep(VoiceModelFailure failure, {int? neededBytes}) {
    if (!ref.mounted) return;
    state = _kept.copyWith(wanted: false);
    _events.add(VoiceModelEvent(VoiceModelEventKind.failed, failure: failure, neededBytes: neededBytes, again: true));
    final text = noticeText;
    _line(_foreground || text == null ? null : text.failed);
  }

  /// Waits, up to [downloadStopWait], for every download that may still
  /// write; true once none may ([downloadStopping] false).
  Future<bool> _writersStopped() async {
    final writing = [
      for (final w in _writers)
        if (!w.isCompleted) w.future,
    ];
    if (writing.isNotEmpty) {
      await Future.wait(writing).timeout(downloadStopWait, onTimeout: () => const <void>[]);
    }
    return !downloadStopping;
  }

  Future<void> _dropStaging() async {
    try {
      await (await _platform.files())?.clearStaging();
    } catch (_) {}
  }

  /// Mirror download; null when every file is in place.
  Future<VoiceModelFailure?> _fetch(int run, List<VoiceDownloadJob> jobs) async {
    final writer = Completer<void>();
    _writers.add(writer);
    unawaited(writer.future.whenComplete(() => _writers.remove(writer)));
    final VoiceDownloadRun download;
    try {
      download = await _platform.download(jobs);
    } catch (_) {
      // Never started.
      writer.complete();
      return VoiceModelFailure.unknown;
    }
    // Stopped writing once it reports, however it ends (also when cancelled before it was in hand).
    unawaited(download.done.then((_) {}, onError: (Object _) {}).whenComplete(writer.complete));
    if (!_alive(run)) {
      download.cancel();
      return null;
    }
    _download = download;
    final sub = download.progress.listen((done) {
      if (!_alive(run)) return;
      state = state.copyWith(doneBytes: done);
      _notice(VoiceModelStatus.downloading);
    });
    try {
      await download.done;
      return null;
    } on VoiceDownloadException catch (e) {
      return switch (e.kind) {
        VoiceDownloadError.storage => VoiceModelFailure.storage,
        VoiceDownloadError.cancelled => VoiceModelFailure.unknown,
        _ => VoiceModelFailure.network,
      };
    } catch (_) {
      return VoiceModelFailure.unknown;
    } finally {
      await sub.cancel();
      if (identical(_download, download)) _download = null;
    }
  }

  /// Bundle on, then the engine's preparation (its own download when files
  /// are still missing), followed until it settles. After every answer the
  /// run is checked before it changes anything: a cancel or delete that came
  /// meanwhile (or a new engine) must not see the bundle switched back on.
  Future<void> _prepare(int run, DshClient client, VoiceModelFiles files, List<VoiceModelAsset> assets) async {
    if (!_current(run, client)) return;
    try {
      final bundles = await client.listBundles();
      if (!_current(run, client)) return;
      final bundle = bundles.where((b) => b.name == voiceInputBundle).firstOrNull;
      if (bundle == null) {
        state = state.copyWith(status: VoiceModelStatus.unsupported);
        return;
      }
      if (!bundle.enabled) {
        final result = await client.setBundleEnabled(voiceInputBundle, true);
        if (!_current(run, client)) return;
        if (result.application != PluginApplication.applied) {
          _fail(VoiceModelFailure.engine);
          return;
        }
      }
      // The speech methods appear once the bundle is live.
      SpeechProviderView? provider;
      for (var i = 0; i < 20 && provider == null; i++) {
        provider = await _provider(client);
        if (provider == null) await Future<void>.delayed(pollEvery);
        if (!_current(run, client)) return;
      }
      if (provider == null) {
        _fail(VoiceModelFailure.engine);
        return;
      }
      if (provider.usable) {
        await _finish(run, client, assets);
        return;
      }
      if (!_preparing(provider.phase)) await client.prepareSpeech(voiceModelProviderId);
    } catch (_) {
      if (_current(run, client)) _fail(VoiceModelFailure.engine);
      return;
    }
    if (!_current(run, client)) return;
    state = state.copyWith(status: VoiceModelStatus.preparing);
    _notice(VoiceModelStatus.preparing);
    _follow(client, run, files, assets, announce: true);
  }

  /// Polls the engine's preparation until it settles.
  void _follow(DshClient client, int run, VoiceModelFiles files, List<VoiceModelAsset> assets, {required bool announce}) {
    _poll?.cancel();
    var misses = 0;
    var busy = false;
    // The engine's own download has only a 1 h deadline: a dead line would
    // sit at the same byte count for that long. Give up after a quiet minute.
    var lastBytes = -1;
    var lastMove = DateTime.now();
    _poll = Timer.periodic(pollEvery, (timer) async {
      if (busy) return;
      if (!_current(run, client)) {
        timer.cancel();
        return;
      }
      busy = true;
      try {
        final provider = await _provider(client);
        if (!_current(run, client)) return;
        if (provider == null) {
          if (++misses >= 10) {
            timer.cancel();
            _fail(VoiceModelFailure.engine);
          }
          return;
        }
        misses = 0;
        if (provider.usable) {
          timer.cancel();
          await _finish(run, client, assets);
        } else if (provider.phase == 'failed') {
          timer.cancel();
          _fail(_providerFailure(provider.preparation));
        } else if (provider.phase == 'cancelled' || provider.phase == 'unprepared') {
          timer.cancel();
          if (_cancelled || !announce) {
            state = state.copyWith(status: VoiceModelStatus.absent, doneBytes: files.presentBytes(assets));
          } else {
            _fail(VoiceModelFailure.unknown);
          }
        } else {
          final p = provider.preparation;
          final bytes = p.phase == 'downloading' ? (p.completedBytes ?? 0) : -1;
          final now = DateTime.now();
          if (bytes != lastBytes || bytes < 0) {
            lastBytes = bytes;
            lastMove = now;
          } else if (now.difference(lastMove) > stall) {
            timer.cancel();
            try {
              await client.cancelSpeechPreparation(voiceModelProviderId, timeout: const Duration(seconds: 20));
            } catch (_) {}
            if (_current(run, client)) _fail(VoiceModelFailure.timeout);
            return;
          }
          _show(provider, files, assets);
        }
      } catch (_) {
        if (++misses >= 10 && _current(run, client)) {
          timer.cancel();
          _fail(VoiceModelFailure.engine);
        }
      } finally {
        busy = false;
      }
    });
  }

  void _show(SpeechProviderView provider, VoiceModelFiles files, List<VoiceModelAsset> assets) {
    final p = provider.preparation;
    if (p.phase == 'downloading') {
      // The engine's own download: files done plus the one in flight.
      final done = assets
          .where((a) => a.name != p.resource && files.complete([a]))
          .fold<int>(0, (n, a) => n + a.bytes);
      state = state.copyWith(
        status: VoiceModelStatus.downloading,
        doneBytes: done + (p.completedBytes ?? 0),
        totalBytes: _total(assets),
      );
      _notice(VoiceModelStatus.downloading);
    } else {
      state = state.copyWith(status: VoiceModelStatus.preparing, doneBytes: _total(assets), totalBytes: _total(assets));
      _notice(VoiceModelStatus.preparing);
    }
  }

  Future<void> _finish(int run, DshClient client, List<VoiceModelAsset> assets) async {
    try {
      final catalog = await client.speechCatalog();
      if (!_current(run, client)) return;
      if (catalog != null && catalog.providerId != voiceModelProviderId) {
        await client.configureSpeech(providerId: voiceModelProviderId);
      }
    } catch (_) {
      // The recognizer is ready; the default stays as the engine has it.
    }
    if (!_current(run, client)) return;
    _settledReady(_total(assets));
    _events.add(const VoiceModelEvent(VoiceModelEventKind.ready));
    final text = noticeText;
    _line(_foreground || text == null ? null : text.ready);
  }

  void _settledReady(int total) {
    _poll?.cancel();
    state = state.copyWith(status: VoiceModelStatus.ready, doneBytes: total, totalBytes: total, clearFailure: true);
    if (state.wanted) unawaited(_setWanted(false));
  }

  void _fail(VoiceModelFailure failure, {int? neededBytes}) {
    _poll?.cancel();
    if (!ref.mounted) return;
    // A failed download is not retried by itself; the settings page offers 重试.
    unawaited(_setWanted(false));
    state = state.copyWith(status: VoiceModelStatus.failed, failure: failure, neededBytes: neededBytes);
    _events.add(VoiceModelEvent(VoiceModelEventKind.failed, failure: failure, neededBytes: neededBytes));
    final text = noticeText;
    _line(_foreground || text == null ? null : text.failed);
  }

  void _notice(VoiceModelStatus status) {
    final text = noticeText;
    if (text == null) return;
    final percent = status == VoiceModelStatus.preparing ? -1 : ((state.fraction ?? 0) * 100).floor();
    _line(percent < 0 ? text.preparing : text.downloading(percent), progress: percent);
  }

  /// The engine notification's line; null [text] restores the usual one.
  void _line(String? text, {int? progress}) => _gate.add(text, text == null ? null : progress);

  bool _alive(int run) => ref.mounted && run == _run;

  bool _current(int run, DshClient client) => _alive(run) && identical(client, _client);

  static bool _preparing(String phase) =>
      const {'downloading', 'checking', 'loading', 'waking', 'cancelling'}.contains(phase);

  static int _total(List<VoiceModelAsset> assets) => assets.fold<int>(0, (n, a) => n + a.bytes);

  static Future<SpeechProviderView?> _provider(DshClient client) async {
    final catalog = await client.speechCatalog().timeout(const Duration(seconds: 6));
    return catalog?.providers.where((p) => p.id == voiceModelProviderId).firstOrNull;
  }

  static VoiceModelFailure _providerFailure(SpeechPreparation p) => switch (p.failure?.reason) {
    'network' || 'dns' => VoiceModelFailure.network,
    'timeout' => VoiceModelFailure.timeout,
    'certificate' => VoiceModelFailure.certificate,
    'http' => VoiceModelFailure.server,
    'integrity' => VoiceModelFailure.integrity,
    'storage' => VoiceModelFailure.storage,
    _ => VoiceModelFailure.unknown,
  };
}

final voiceModelProvider = NotifierProvider<VoiceModelController, VoiceModelState>(VoiceModelController.new);

/// Bytes as the settings page shows them: 「240 MB」.
String voiceModelMegabytes(int bytes) => '${(bytes / 1000000).round()} MB';
