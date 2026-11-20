import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import '../files/support/files_harness.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final file in ['README.md', 'out/sales.csv', 'bundle.zip', 'out/chart.png']) {
    testWidgets('preview controls are symmetric for $file', (tester) async {
      usePhoneView(tester);
      final ws = sampleWorkspace()..write('bundle.zip', 'PK');
      await tester.pumpWidget(filesApp(FilePreviewPage(sessionId: 's1', path: '${ws.root}/$file', bytes: 2048), ws));
      await pumpFrames(tester, 8);
      final share = tester.getRect(find.byTooltip('分享'));
      final more = tester.getRect(find.byTooltip('更多操作'));
      final back = tester.getRect(find.byTooltip('返回'));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(more.left - share.right, closeTo(8, 0.01));
      expect(width - more.right, closeTo(12, 0.01));
      expect(share.center.dy, closeTo(back.center.dy, 0.01));
      expect(more.center.dy, closeTo(back.center.dy, 0.01));
      if (file == 'out/sales.csv' || file == 'bundle.zip') {
        final title = tester.getRect(find.byKey(const ValueKey('preview-frame-title')));
        final meta = tester.getRect(find.byKey(const ValueKey('preview-frame-meta')));
        expect(title.left, closeTo(68, 0.01));
        expect(meta.left, closeTo(title.left, 0.01));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('preview-frame-meta'))).data,
          file == 'bundle.zip' ? '工作区 · 2.0 KB' : 'out · 2.0 KB',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
