import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../voice/streaming_asr_download.dart';
import '../voice/streaming_asr_model.dart';
import 'streaming_asr_state.dart';
import 'streaming_pcm_state.dart';

enum StreamingAsrModelStatus { checking, absent, downloading, verifying, ready, cancelling, deleting, failed }

class StreamingAsrModelState {
  const StreamingAsrModelState({
    this.status = StreamingAsrModelStatus.checking,
    this.doneBytes = 0,
    this.totalBytes = streamingAsrDefaultBytes,
    this.model,
    this.error,
    this.blocked = false,
  });

  final StreamingAsrModelStatus status;

  /// Ready, but it once crashed the app on this phone: live words stay off.
  final bool blocked;
  final int doneBytes;
  final int totalBytes;
  final StreamingAsrModel? model;
  final Object? error;
  double get fraction => totalBytes == 0 ? 0 : (doneBytes / totalBytes).clamp(0, 1);
  bool get busy => switch (status) {
    StreamingAsrModelStatus.absent || StreamingAsrModelStatus.ready || StreamingAsrModelStatus.failed => false,
    _ => true,
  };
}

/// Override for other hosts; the pinned hashes still apply.
final streamingAsrManifestProvider = Provider<StreamingAsrModelManifest>((ref) => streamingAsrDefaultManifest);

final streamingAsrModelStoreProvider = FutureProvider<StreamingAsrModelStore>((ref) async {
  final manifest = ref.watch(streamingAsrManifestProvider);
  StreamingAsrModelStore? store;
  ref.onDispose(() {
    if (store != null) unawaited(store.cancel());
  });
  final support = await getApplicationSupportDirectory();
  return store = StreamingAsrModelStore(Directory('${support.path}/speech/streaming-asr'), manifest: manifest);
});

class StreamingAsrModelController extends Notifier<StreamingAsrModelState> {
  late Future<StreamingAsrModelStore> _store;
  int _generation = 0;

  @override
  StreamingAsrModelState build() {
    _store = ref.watch(streamingAsrModelStoreProvider.future);
    final generation = ++_generation;
    unawaited(_refresh(generation));
    return const StreamingAsrModelState();
  }

  bool _alive(int generation) => ref.mounted && generation == _generation;

  Future<void> refresh() {
    if (state.busy) return Future.value();
    return _refresh(++_generation);
  }

  Future<void> _refresh(int generation) async {
    try {
      final store = await _store;
      final model = await store.installed();
      final done = model == null ? await store.downloadedBytes() : store.manifest.bytes;
      if (!_alive(generation)) return;
      state = StreamingAsrModelState(
        status: model == null ? StreamingAsrModelStatus.absent : StreamingAsrModelStatus.ready,
        doneBytes: done,
        totalBytes: store.manifest.bytes,
        model: model,
        blocked: model != null && store.trial.failed,
      );
    } catch (error) {
      if (_alive(generation)) state = StreamingAsrModelState(status: StreamingAsrModelStatus.failed, error: error);
    }
  }

  Future<void> download() async {
    if (state.busy) return;
    final generation = ++_generation;
    state = StreamingAsrModelState(status: StreamingAsrModelStatus.downloading, totalBytes: state.totalBytes);
    try {
      final store = await _store;
      if (!_alive(generation)) return;
      final model = await store.download(
        onProgress: (progress) {
          if (!_alive(generation)) return;
          state = StreamingAsrModelState(
            status: switch (progress.phase) {
              StreamingAsrDownloadPhase.downloading => StreamingAsrModelStatus.downloading,
              StreamingAsrDownloadPhase.verifying => StreamingAsrModelStatus.verifying,
            },
            doneBytes: progress.doneBytes,
            totalBytes: progress.totalBytes,
          );
        },
      );
      if (!_alive(generation)) return;
      state = StreamingAsrModelState(
        status: StreamingAsrModelStatus.ready,
        doneBytes: store.manifest.bytes,
        totalBytes: store.manifest.bytes,
        model: model,
      );
    } on StreamingAsrDownloadCancelled {
      if (_alive(generation)) await _refresh(generation);
    } catch (error) {
      if (_alive(generation)) {
        state = StreamingAsrModelState(
          status: StreamingAsrModelStatus.failed,
          doneBytes: state.doneBytes,
          totalBytes: state.totalBytes,
          error: error,
        );
      }
    }
  }

  Future<void> cancel() async {
    final generation = ++_generation;
    state = StreamingAsrModelState(status: StreamingAsrModelStatus.cancelling, totalBytes: state.totalBytes);
    try {
      await (await _store).cancel();
      if (_alive(generation)) await _refresh(generation);
    } catch (error) {
      if (_alive(generation)) state = StreamingAsrModelState(status: StreamingAsrModelStatus.failed, error: error);
    }
  }

  Future<void> delete() async {
    final generation = ++_generation;
    state = StreamingAsrModelState(status: StreamingAsrModelStatus.deleting, totalBytes: state.totalBytes);
    try {
      await ref.read(streamingPcmCaptureProvider).stop();
      await ref.read(streamingAsrProvider).stop(finalize: false);
      final store = await _store;
      await store.delete();
      if (_alive(generation)) {
        state = StreamingAsrModelState(status: StreamingAsrModelStatus.absent, totalBytes: store.manifest.bytes);
      }
    } catch (error) {
      if (_alive(generation)) state = StreamingAsrModelState(status: StreamingAsrModelStatus.failed, error: error);
    }
  }
}

final streamingAsrModelProvider = NotifierProvider<StreamingAsrModelController, StreamingAsrModelState>(
  StreamingAsrModelController.new,
);
