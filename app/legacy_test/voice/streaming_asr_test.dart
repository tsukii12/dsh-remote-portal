import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/voice/streaming_asr.dart';

StreamingAsrDecoder _fakeDecoder(StreamingAsrModel model) {
  File(model.tokens).writeAsStringSync('${model.joiner}:loading\n', mode: FileMode.append);
  if (model.encoder == 'slow') {
    // Held until the test lets it go ([StreamingAsrModel.decoder] names the
    // file it writes), at most five seconds.
    final release = File(model.decoder);
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (!release.existsSync() && DateTime.now().isBefore(until)) {
      sleep(const Duration(milliseconds: 2));
    }
  }
  if (model.encoder == 'fail') throw StateError('load failed');
  return _Decoder(model);
}

class _Decoder implements StreamingAsrDecoder {
  _Decoder(this.model);
  final StreamingAsrModel model;
  final values = <int>[];
  var endpoint = false;

  void log(String text) => File(model.tokens).writeAsStringSync('${model.joiner}:$text\n', mode: FileMode.append);

  @override
  void feed(Float32List samples) {
    final value = (samples.first * 32768).round();
    if (value < 0) throw StateError('decode failed');
    log('feed:$value');
    endpoint = value == 0;
    if (!endpoint) values.add(value);
  }

  @override
  String get text => values.join(',');
  @override
  bool get isEndpoint => endpoint;
  @override
  void reset() {
    log('reset');
    endpoint = false;
    values.clear();
  }

  @override
  void finish() => log('finish');
  @override
  void close() => log('close');
}

Uint8List _pcm(int value) {
  final data = ByteData(640);
  for (var i = 0; i < 320; i++) {
    data.setInt16(i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late Directory directory;
  late File log;
  late File release;
  late StreamingAsr asr;
  late List<StreamingAsrEvent> events;
  late StreamSubscription<StreamingAsrEvent> subscription;

  StreamingAsrModel model([String kind = 'normal', String name = 'one']) =>
      StreamingAsrModel(encoder: kind, decoder: release.path, joiner: name, tokens: log.path);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('streaming-asr-test-');
    log = File('${directory.path}/decoder.log');
    release = File('${directory.path}/release');
    asr = StreamingAsr(createDecoder: _fakeDecoder);
    events = [];
    subscription = asr.events.listen(events.add);
  });

  tearDown(() async {
    if (!release.existsSync()) release.writeAsStringSync('');
    await asr.dispose();
    await subscription.cancel();
    await directory.delete(recursive: true);
  });

  test('queued PCM stays ordered and endpoint emits one final before the next utterance', () async {
    await asr.start(model());
    final first = _pcm(1);
    final pending = asr.feed(first);
    first.fillRange(0, first.length, 0);
    await Future.wait([pending, asr.feed(_pcm(2)), asr.feed(_pcm(0)), asr.feed(_pcm(3))]);
    await asr.stop();
    expect(events.map((e) => e.text), ['1', '1,2', '1,2', '3', '3']);
    expect(events.whereType<StreamingAsrFinal>().map((e) => e.text), ['1,2', '3']);
    expect(log.readAsLinesSync(), [
      'one:loading',
      'one:feed:1',
      'one:feed:2',
      'one:feed:0',
      'one:reset',
      'one:feed:3',
      'one:finish',
      'one:close',
    ]);
    expect(asr.active, isFalse);
  });

  test('cancel during model loading drops queued frames and closes the model', () async {
    final started = asr.start(model('slow'));
    while (!await log.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final frame = asr.feed(_pcm(1));
    final stopped = asr.stop(finalize: false);
    // The load holds the recognition isolate, not this one: a timer still fires.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    release.writeAsStringSync('');
    await Future.wait([started, frame, stopped]);
    expect(events, isEmpty);
    expect(log.readAsLinesSync(), ['one:loading', 'one:close']);
    expect(asr.active, isFalse);
  });

  test('a new start retires the old session and can recognize after cancellation', () async {
    final first = asr.start(model('slow', 'old'));
    while (!await log.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final oldFrame = asr.feed(_pcm(1));
    final second = asr.start(model('normal', 'new'));
    final newFrame = asr.feed(_pcm(2));
    release.writeAsStringSync('');
    await Future.wait([first, oldFrame, second, newFrame]);
    await asr.stop(finalize: false);
    expect(events.map((e) => e.text), ['2']);
    expect(log.readAsLinesSync(), ['old:loading', 'old:close', 'new:loading', 'new:feed:2', 'new:close']);
  });

  test('model and inference errors are returned and a later start can recover', () async {
    await expectLater(asr.start(model('fail')), throwsStateError);
    await asr.start(model());
    await expectLater(asr.feed(_pcm(-1)), throwsStateError);
    expect(asr.active, isFalse);
    await asr.start(model('normal', 'retry'));
    await asr.feed(_pcm(3));
    await asr.stop();
    expect(events.map((e) => e.text), ['3', '3']);
    expect(log.readAsLinesSync().where((line) => line.endsWith(':close')), ['one:close', 'retry:close']);
  });

  test('dispose cancels an in-flight load and is idempotent', () async {
    final started = asr.start(model('slow'));
    while (!await log.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final disposed = [asr.dispose(), asr.dispose()];
    release.writeAsStringSync('');
    await Future.wait([started, ...disposed]);
    expect(log.readAsLinesSync(), ['one:loading', 'one:close']);
    await expectLater(asr.start(model()), throwsStateError);
    expect(events, isEmpty);
  });
}
