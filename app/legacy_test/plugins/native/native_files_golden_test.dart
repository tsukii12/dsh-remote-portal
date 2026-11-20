// File selection uses system UI. These goldens cover its signed plugin entry
// and the old-client fallback; system chooser UI needs device verification.
// Generate baselines locally with:
// flutter test --update-goldens test/plugins/native/native_files_golden_test.dart
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import '../../support/english_preview.dart';
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      for (final supported in [false, true]) {
        final suffix = '${english ? 'en' : 'zh'}_${brightness.name}_${supported ? 'ready' : 'unavailable'}';
        testWidgets('files entry at 320dp and 2x text ($suffix)', (tester) async {
          if (english) useEnglish();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 800);
          addTearDown(tester.view.reset);
          final title = english ? 'File digest' : '文件摘要';
          final bridge = FakeBridge(
            contributions([
              plugin(
                'file-example',
                title: title,
                icon: 'document',
                panels: [
                  {'id': 'files', 'title': title, 'icon': 'document'},
                ],
              ),
            ]),
          );
          bridge.views['file-example/files'] = DshGoView(
            pkg: 'file-example',
            id: 'files',
            title: title,
            live: false,
            view: supported
                ? {
                    'type': 'stack',
                    'children': [
                      {
                        'type': 'text',
                        'text': english ? 'Choose files to calculate their SHA-256' : '选择文件，计算内容的 SHA-256',
                      },
                      {
                        'type': 'actions',
                        'items': [
                          {'label': english ? 'Files' : '文件', 'icon': 'document', 'action': 'chooseFiles'},
                          {'label': english ? 'Images' : '图片', 'icon': 'image', 'action': 'chooseImages'},
                        ],
                      },
                      {'type': 'metric', 'label': english ? 'Files read' : '已读文件', 'value': 1},
                      {
                        'type': 'list',
                        'items': [
                          {
                            'title': 'note.txt',
                            'subtitle': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
                            'trailing': '3 B',
                            'icon': 'document',
                          },
                        ],
                      },
                    ],
                  }
                : {
                    'type': 'text',
                    'text': english ? 'File selection is unavailable on this connection' : '当前连接不支持文件选择',
                    'tone': 'muted',
                  },
          );
          Widget page = Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
              child: NativePanelPage(
                panel: NativePanel(
                  package: 'file-example',
                  id: 'files',
                  title: title,
                  icon: 'document',
                  placement: const {'features'},
                  live: false,
                ),
              ),
            ),
          );
          if (english) page = inEnglish(page);
          await tester.pumpWidget(testApp(page, brightness: brightness, overrides: nativeOverrides(bridge)));
          await pumpFrames(tester, 10);
          expect(tester.takeException(), isNull);
          expect(find.text(english ? 'Files' : '文件'), supported ? findsOneWidget : findsNothing);
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/files_$suffix.png'));
        });
      }
    }
  }
}
