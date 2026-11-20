import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

// Valid one-page PDF; both concurrent render requests return identical bytes.
List<int> blankPdf() {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (final object in [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>',
  ]) {
    offsets.add(out.length);
    out.write('${offsets.length - 1} 0 obj\n$object\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 4\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return ascii.encode(out.toString());
}

// Same steps as SDK file_impl.dart writeAsBytes, with only a scheduling gate
// after the real open. No byte changes, fake write failure or fake filesystem.
class _WriteGateFile implements File {
  _WriteGateFile(this.inner, this.opened, this.release);
  final File inner;
  final Completer<void> opened;
  final Completer<void> release;
  @override
  String get path => inner.path;
  @override
  bool existsSync() => inner.existsSync();
  @override
  File renameSync(String newPath) => inner.renameSync(newPath);
  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) async {
    final handle = await inner.open(mode: mode);
    try {
      if (!opened.isCompleted) opened.complete();
      await release.future;
      await handle.writeFrom(bytes, 0, bytes.length);
      if (flush) await handle.flush();
      return this;
    } finally {
      await handle.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('second identical Office cache write must not truncate the first returned PDF', () async {
    final cache = await Directory.systemTemp.createTemp('office-cache-publish-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pdf = blankPdf();
    final bothRendering = Completer<void>();
    final firstRendering = Completer<void>();
    final secondResponse = Completer<void>();
    final opened = Completer<void>();
    final release = Completer<void>();
    final errors = <Object>[];
    var renders = 0;
    final serving = server.listen((req) async {
      try {
        final input = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        Object value;
        if (req.uri.path == '/api/workspaceFiles/stat') {
          value = {'absolutePath': '/workspace/sample.docx', 'version': 'unchanged', 'bytes': 100};
        } else if (req.uri.path == '/api/officeToPdf/render') {
          final number = ++renders;
          if (number == 1) firstRendering.complete();
          if (renders == 2) bothRendering.complete();
          await bothRendering.future;
          if (number == 2) await secondResponse.future;
          value = {'data': pdf, 'missingFonts': <String>[]};
        } else {
          throw StateError('unexpected ${req.uri.path}');
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': input['rpcId'],
            'result': {'ok': true, 'value': value},
          }),
        );
        await req.response.close();
      } catch (e) {
        errors.add(e);
        req.response.statusCode = 500;
        await req.response.close();
      }
    });
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    final files = ArtifactFiles(
      connection: HostConnection(hostId: '', client: client, label: 'synthetic', isLocal: false),
      channel: const FilesChannel(),
      cacheRoot: () async => cache,
    );
    const artifact = Artifact(path: '/workspace/sample.docx', origin: ArtifactOrigin.linked, turn: 0);
    final outer = Zone.current;
    addTearDown(() async {
      if (!secondResponse.isCompleted) secondResponse.complete();
      if (!release.isCompleted) release.complete();
      await client.close();
      await server.close(force: true);
      await serving.cancel();
      await cache.delete(recursive: true);
      expect(errors, isEmpty);
    });
    final first = files.officePdf('session', artifact);
    await firstRendering.future.timeout(const Duration(seconds: 5));
    final second = IOOverrides.runZoned(
      () => files.officePdf('session', artifact),
      createFile: (path) {
        final file = outer.run(() => File(path));
        return path.endsWith('.pdf') ? _WriteGateFile(file, opened, release) : file;
      },
    );
    final returned = await first.timeout(const Duration(seconds: 5));
    expect(await returned.readAsBytes(), pdf);
    secondResponse.complete();
    await opened.future.timeout(const Duration(seconds: 5));
    final during = await returned.readAsBytes();
    release.complete();
    await second.timeout(const Duration(seconds: 5));
    expect(await returned.readAsBytes(), pdf, reason: 'gate release finishes the unchanged real write');
    expect(renders, 2);
    expect(
      await cache.list(recursive: true).where((entry) => entry.path.split('/').last.startsWith('.part-')).toList(),
      isEmpty,
    );
    expect(during, pdf, reason: 'a completed preview must not observe the later writer truncating its PDF');
  });
}
