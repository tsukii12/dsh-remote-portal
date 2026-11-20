import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'streaming_asr_model.dart';

export 'streaming_asr_model.dart';

sealed class StreamingAsrEvent {
  const StreamingAsrEvent(this.text);
  final String text;
}

final class StreamingAsrPartial extends StreamingAsrEvent {
  const StreamingAsrPartial(super.text);
}

final class StreamingAsrFinal extends StreamingAsrEvent {
  const StreamingAsrFinal(super.text);
}

/// A synchronous decoder owned exclusively by the recognition isolate.
abstract interface class StreamingAsrDecoder {
  void feed(Float32List samples);
  String get text;
  bool get isEndpoint;
  void reset();
  void finish();
  void close();
}

typedef StreamingAsrDecoderFactory = StreamingAsrDecoder Function(StreamingAsrModel model);

/// 16 kHz mono PCM16LE in; ordered hypotheses out. This does not start the microphone.
class StreamingAsr {
  StreamingAsr({StreamingAsrDecoderFactory createDecoder = _SherpaDecoder.new})
    : _createDecoder = createDecoder; // ignore: prefer_initializing_formals

  final StreamingAsrDecoderFactory _createDecoder;
  final _events = StreamController<StreamingAsrEvent>.broadcast();
  Future<void> _tail = Future.value();
  _Worker? _worker;
  var _run = 0;
  var _loadedRun = 0;
  var _active = false;
  var _disposed = false;
  var _feeding = 0;

  /// Frames queued for the decoder at most (a second of 20 ms frames); past
  /// that a decoder slower than speech drops new audio rather than lag further.
  static const maxQueued = 50;

  Stream<StreamingAsrEvent> get events => _events.stream;
  bool get active => _active && _loadedRun == _run;

  /// Replaces any previous recognition. Subscribe to [events] before feeding PCM.
  Future<void> start(StreamingAsrModel model) {
    if (_disposed) return Future.error(StateError('StreamingAsr is disposed'));
    final run = ++_run;
    return _enqueue(() async {
      if (run != _run) return;
      _active = false;
      if (_worker == null || _worker!.closed) {
        _worker = await _Worker.open(_createDecoder, (result) {
          if (!_disposed && result.run == _run) _events.add(result.event);
        });
      }
      await _worker!.request(_Start(run, model));
      _loadedRun = run;
      _active = true;
    });
  }

  /// Resolves after decoding this frame. Await it when applying backpressure.
  Future<void> feed(Uint8List pcm16le) {
    if (_disposed) return Future.error(StateError('StreamingAsr is disposed'));
    if (pcm16le.length.isOdd) return Future.error(const FormatException('PCM16 must contain whole samples'));
    if (_feeding >= maxQueued) return Future.value();
    final run = _run;
    final pcm = TransferableTypedData.fromList([pcm16le]);
    _feeding++;
    return _enqueue(() async {
      try {
        if (run != _run) return;
        if (!active) throw StateError('StreamingAsr is not started');
        try {
          await _worker!.request(_Feed(pcm));
        } catch (_) {
          _active = false;
          rethrow;
        }
      } finally {
        _feeding--;
      }
    });
  }

  /// Flushes queued audio and emits its final text. Cancellation drops queued audio and results.
  /// Both forms release the stream and model before returning.
  Future<void> stop({bool finalize = true}) {
    if (_disposed) return _tail;
    if (!finalize) _run++;
    return _enqueue(() => _stop(finalize));
  }

  Future<void> _stop(bool finalize) async {
    try {
      if (_worker != null && !_worker!.closed) await _worker!.request(_Stop(finalize));
    } finally {
      _active = false;
    }
  }

  Future<void> dispose() {
    if (_disposed) return _tail;
    _disposed = true;
    _run++;
    return _enqueue(() async {
      try {
        await _stop(false);
      } finally {
        _worker?.close();
        _worker = null;
        await _events.close();
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class _Start {
  const _Start(this.run, this.model);
  final int run;
  final StreamingAsrModel model;
}

class _Feed {
  const _Feed(this.pcm);
  final TransferableTypedData pcm;
}

class _Stop {
  const _Stop(this.finalize);
  final bool finalize;
}

class _Result {
  const _Result(this.run, this.event);
  final int run;
  final StreamingAsrEvent event;
}

class _Done {
  const _Done();
}

class _Failure {
  const _Failure(this.message, this.stack);
  final String message;
  final String stack;
}

class _Worker {
  _Worker(this.onResult) {
    _receive.listen(_receiveMessage);
  }

  final void Function(_Result) onResult;
  final _receive = ReceivePort();
  final _ready = Completer<SendPort>();
  late final Isolate _isolate;
  late final SendPort _commands;
  Completer<void>? _reply;
  bool closed = false;

  static Future<_Worker> open(StreamingAsrDecoderFactory createDecoder, void Function(_Result) onResult) async {
    final worker = _Worker(onResult);
    try {
      worker._isolate = await Isolate.spawn(
        _recognize,
        (worker._receive.sendPort, createDecoder),
        debugName: 'dsh-streaming-asr',
        onError: worker._receive.sendPort,
        onExit: worker._receive.sendPort,
      );
      worker._commands = await worker._ready.future;
      return worker;
    } catch (_) {
      worker._receive.close();
      rethrow;
    }
  }

  Future<void> request(Object command) {
    if (closed) return Future.error(StateError('Recognition isolate has exited'));
    final reply = Completer<void>();
    _reply = reply;
    _commands.send(command);
    return reply.future;
  }

  void _receiveMessage(Object? message) {
    switch (message) {
      case SendPort():
        _ready.complete(message);
      case _Result():
        onResult(message);
      case _Done():
        _reply!.complete();
        _reply = null;
      case _Failure():
        _reply!.completeError(StateError(message.message), StackTrace.fromString(message.stack));
        _reply = null;
      case null:
        _exited(StateError('Recognition isolate has exited'), StackTrace.current);
      case List():
        _exited(StateError(message[0].toString()), StackTrace.fromString(message[1].toString()));
    }
  }

  void _exited(Object error, StackTrace stack) {
    closed = true;
    _receive.close();
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    _reply?.completeError(error, stack);
    _reply = null;
  }

  void close() {
    closed = true;
    _receive.close();
    _isolate.kill();
  }
}

Future<void> _recognize((SendPort, StreamingAsrDecoderFactory) arguments) async {
  final (replies, createDecoder) = arguments;
  final commands = ReceivePort();
  StreamingAsrDecoder? decoder;
  var run = 0;
  var previous = '';

  void release() {
    final current = decoder;
    decoder = null;
    current?.close();
    previous = '';
  }

  replies.send(commands.sendPort);
  await for (final command in commands) {
    try {
      switch (command) {
        case _Start():
          release();
          decoder = createDecoder(command.model);
          run = command.run;
        case _Feed():
          final bytes = command.pcm.materialize().asByteData();
          final samples = Float32List(bytes.lengthInBytes ~/ 2);
          for (var i = 0; i < samples.length; i++) {
            samples[i] = bytes.getInt16(i * 2, Endian.little) / 32768.0;
          }
          final current = decoder!;
          current.feed(samples);
          final text = current.text;
          if (current.isEndpoint) {
            if (text.isNotEmpty) replies.send(_Result(run, StreamingAsrFinal(text)));
            current.reset();
            previous = '';
          } else if (text != previous) {
            replies.send(_Result(run, StreamingAsrPartial(text)));
            previous = text;
          }
        case _Stop():
          final current = decoder;
          if (current != null && command.finalize) {
            current.finish();
            final text = current.text;
            if (text.isNotEmpty) replies.send(_Result(run, StreamingAsrFinal(text)));
          }
          release();
      }
      replies.send(const _Done());
    } catch (error, stack) {
      try {
        release();
      } finally {
        replies.send(_Failure(error.toString(), stack.toString()));
      }
    }
  }
}

class _SherpaDecoder implements StreamingAsrDecoder {
  factory _SherpaDecoder(StreamingAsrModel model) {
    for (final path in [model.encoder, model.decoder, model.joiner, model.tokens]) {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file || stat.size == 0) {
        throw FileSystemException('ASR model file is missing or empty', path);
      }
    }
    sherpa.initBindings();
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: model.encoder,
            decoder: model.decoder,
            joiner: model.joiner,
          ),
          tokens: model.tokens,
          modelType: 'zipformer',
          numThreads: 2,
          debug: false,
        ),
        rule2MinTrailingSilence: 1.0,
        rule3MinUtteranceLength: 110.0,
      ),
    );
    try {
      return _SherpaDecoder._(recognizer, recognizer.createStream());
    } catch (_) {
      recognizer.free();
      rethrow;
    }
  }

  _SherpaDecoder._(this._recognizer, this._stream);
  final sherpa.OnlineRecognizer _recognizer;
  final sherpa.OnlineStream _stream;
  var _text = '';

  @override
  void feed(Float32List samples) {
    _stream.acceptWaveform(samples: samples, sampleRate: 16000);
    _decode();
  }

  void _decode() {
    var decoded = false;
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
      decoded = true;
    }
    if (decoded) _text = _recognizer.getResult(_stream).text.trim();
  }

  @override
  String get text => _text;
  @override
  bool get isEndpoint => _recognizer.isEndpoint(_stream);
  @override
  void reset() {
    _recognizer.reset(_stream);
    _text = '';
  }

  @override
  void finish() {
    _stream.acceptWaveform(samples: Float32List(4800), sampleRate: 16000);
    _stream.inputFinished();
    _decode();
  }

  @override
  void close() {
    try {
      _stream.free();
    } finally {
      _recognizer.free();
    }
  }
}
