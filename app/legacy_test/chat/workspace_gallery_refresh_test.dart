import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';
import '../media/support.dart' show drawPicture;
import 'support/harness.dart';

class _LocalPictures extends ArtifactFiles {
  _LocalPictures(this.dir) : super(connection: fakeConnection, channel: const FilesChannel());
  final Directory dir;

  @override
  bool get isLocal => true;

  @override
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) async => File('${dir.path}/${artifact.name}');
}

Future<void> _decode(WidgetTester tester) async {
  // Build the FileImage in the real-async zone as well as decoding it there;
  // otherwise a fake-zone pending file read can strand precacheImage's listener.
  await tester.runAsync(() async {
    await tester.pumpAndSettle();
    final image = find.byType(Image).first;
    final provider = tester.widget<Image>(image).image;
    await precacheImage(provider, tester.element(image)).timeout(const Duration(seconds: 5));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('revisiting a workspace image evicts pixels changed while another file was watched', (tester) async {
    usePhoneView(tester);
    final dir = Directory.systemTemp.createTempSync('gallery-refresh-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final a = File('${dir.path}/a.png')..writeAsBytesSync(tinyPng);
    File('${dir.path}/b.png').writeAsBytesSync(tinyPng);
    final changed = (await tester.runAsync(() => drawPicture(7, 3)))!;
    final workspace = MemoryWorkspace(files: {'a.png': 'a', 'b.png': 'b'});
    final images = [
      for (final name in ['a.png', 'b.png']) Artifact(path: '/root/work/$name', origin: ArtifactOrigin.linked, turn: 0),
    ];
    await tester.pumpWidget(
      filesApp(
        ArtifactPreviewPage(sessionId: 's1', artifact: images.first, gallery: images),
        workspace,
        overrides: [artifactFilesProvider.overrideWithValue(_LocalPictures(dir))],
      ),
    );
    await _decode(tester);
    final original = tester.widget<RawImage>(find.byType(RawImage).hitTestable()).image!;
    expect(original.width, 4);
    expect(original.height, 4);
    await tester.drag(find.byType(PageView), const Offset(-320, 0));
    await _decode(tester);
    expect(workspace.watching('a.png'), 0);
    a.writeAsBytesSync(changed);
    await tester.drag(find.byType(PageView), const Offset(320, 0));
    await _decode(tester);
    final pixels = tester.widget<RawImage>(find.byType(RawImage).hitTestable()).image!;
    expect(pixels.width, 7);
    expect(pixels.height, 3);
    expect(tester.takeException(), isNull);
  });
}
