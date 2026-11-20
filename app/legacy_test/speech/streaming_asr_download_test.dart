import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/voice/streaming_asr_download.dart';
import 'package:flutter_test/flutter_test.dart';

/// Four small files served like Hugging Face's `resolve` URLs.
class _Host {
  _Host(this.server);

  final HttpServer server;
  final ranges = <String?>[];
  int failWith = 0;

  String get origin => 'http://${server.address.address}:${server.port}';

  static Future<_Host> start(Map<String, Uint8List> files) async {
    final host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    host.server.listen((request) async {
      final name = request.uri.pathSegments.last;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      host.ranges.add(range);
      final body = files[name]!;
      if (host.failWith != 0) {
        request.response.statusCode = host.failWith;
      } else if (range != null) {
        final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..add(body.sublist(from));
      } else {
        request.response.add(body);
      }
      await request.response.close();
    });
    return host;
  }
}

void main() {
  final files = <String, Uint8List>{
    for (final (i, name) in ['e.onnx', 'd.onnx', 'j.onnx', 'tokens.txt'].indexed)
      name: Uint8List.fromList(List.generate(3000 + i, (k) => (k * 31 + i) & 0xff)),
  };
  StreamingAsrFile file(String name, {String? hash}) =>
      StreamingAsrFile(name, files[name]!.length, hash ?? sha256.convert(files[name]!).toString());
  StreamingAsrModelManifest manifest(List<String> hosts, {String? tokensHash}) => StreamingAsrModelManifest(
    hosts: hosts,
    repository: 'k2/zipformer',
    revision: 'abc',
    encoder: file('e.onnx'),
    decoder: file('d.onnx'),
    joiner: file('j.onnx'),
    tokens: file('tokens.txt', hash: tokensHash),
  );

  late Directory dir;
  late _Host host;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('streaming-asr-');
    host = await _Host.start(files);
  });

  tearDown(() async {
    await host.server.close(force: true);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('fetches the four files, checks them once, and is then installed without asking again', () async {
    final store = StreamingAsrModelStore(dir, manifest: manifest([host.origin]));
    expect(await store.installed(), isNull);
    final model = await store.download();
    expect(await File(model.encoder).readAsBytes(), files['e.onnx']);
    expect(await File(model.tokens).readAsBytes(), files['tokens.txt']);
    expect(host.ranges, hasLength(4));
    expect((await store.installed())?.joiner, model.joiner);
    await store.download();
    expect(host.ranges, hasLength(4));
  });

  test('a part already here is resumed with a range', () async {
    final store = StreamingAsrModelStore(dir, manifest: manifest([host.origin]));
    await File('${dir.path}/e.onnx.part').writeAsBytes(files['e.onnx']!.sublist(0, 1000));
    final model = await store.download();
    expect(host.ranges.first, 'bytes=1000-');
    expect(await File(model.encoder).readAsBytes(), files['e.onnx']);
  });

  test('a host that fails gives way to the next', () async {
    final down = await _Host.start(files)
      ..failWith = HttpStatus.serviceUnavailable;
    addTearDown(() => down.server.close(force: true));
    final store = StreamingAsrModelStore(dir, manifest: manifest([down.origin, host.origin]));
    final model = await store.download();
    expect(await File(model.decoder).readAsBytes(), files['d.onnx']);
    expect(down.ranges, hasLength(4));
  });

  test('a file that does not match its hash is thrown away and fails the download', () async {
    final store = StreamingAsrModelStore(dir, manifest: manifest([host.origin], tokensHash: '0' * 64));
    await expectLater(store.download(), throwsA(isA<FormatException>()));
    expect(await File('${dir.path}/tokens.txt.part').exists(), isFalse);
    expect(await store.installed(), isNull);
  });

  test('a file longer than it should be is cut off and thrown away', () async {
    final short = StreamingAsrFile(
      'e.onnx',
      files['e.onnx']!.length - 100,
      sha256.convert(files['e.onnx']!).toString(),
    );
    final store = StreamingAsrModelStore(
      dir,
      manifest: StreamingAsrModelManifest(
        hosts: [host.origin],
        repository: 'k2/zipformer',
        revision: 'abc',
        encoder: short,
        decoder: file('d.onnx'),
        joiner: file('j.onnx'),
        tokens: file('tokens.txt'),
      ),
    );
    await expectLater(store.download(), throwsA(isA<HttpException>()));
    final left = dir.listSync(recursive: true).whereType<File>().map((f) => f.path).where((p) => p.contains('e.onnx'));
    expect(left, isEmpty);
  });

  test('delete removes everything', () async {
    final store = StreamingAsrModelStore(dir, manifest: manifest([host.origin]));
    await store.download();
    await store.delete();
    expect(await dir.exists(), isFalse);
    expect(await store.installed(), isNull);
  });
}
