import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';
import 'support/harness.dart';

void main() {
  for (final extension in ['docx', 'html']) {
    for (final converts in [false, true]) {
      testWidgets('$extension menu advertises only supported preview modes (converter: $converts)', (tester) async {
        final artifact = Artifact(path: '/root/workspace/document.$extension', origin: ArtifactOrigin.linked, turn: 1);
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showArtifactMenu(context, artifact: artifact, canFetch: true, officeToPdf: converts),
                  child: const Text('open menu'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open menu'));
        await tester.pumpAndSettle();
        expect(find.text('预览'), extension == 'docx' && converts ? findsOneWidget : findsNothing);
        expect(find.text('用其他应用打开'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('opening HTML as a workspace preview displays source code', (tester) async {
    const source = '<h1>Preview contract</h1><script>throw new Error("must stay text")</script>';
    final workspace = sampleWorkspace()..write('page.html', source);
    await tester.pumpWidget(filesApp(FilePreviewPage(sessionId: 's1', path: '${workspace.root}/page.html'), workspace));
    await pumpFrames(tester, 8);
    expect(previewModeOf('page.html'), PreviewMode.text);
    expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).code, contains(source));
    expect(tester.takeException(), isNull);
  });
}
