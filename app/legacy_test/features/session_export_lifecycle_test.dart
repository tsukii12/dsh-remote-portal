import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_export.dart';
import 'package:dsh_app/ui/features/session_export_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;

class _PendingExporter extends SessionLogExporter {
  _PendingExporter() : super(connection: fakeConnection, channel: const FilesChannel());
  final pending = Completer<String>();
  final calls = <String>[];
  int completed = 0;

  @override
  bool get supported => true;

  @override
  Future<void> share(String sessionId) async {
    calls.add('share:$sessionId');
    try {
      await pending.future;
    } finally {
      completed++;
    }
  }

  @override
  Future<String> saveToDownloads(String sessionId) async {
    calls.add('save:$sessionId');
    try {
      return await pending.future;
    } finally {
      completed++;
    }
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final share in [true, false]) {
    for (final leave in [false, true]) {
      testWidgets('${share ? 'share' : 'save'} failure ${leave ? 'after pop is quiet' : 'on page is shown'}', (
        tester,
      ) async {
        final exporter = _PendingExporter();
        usePhoneView(tester);
        await tester.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            overrides: [
              activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
              sessionLogExporterProvider.overrideWithValue(exporter),
            ],
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context)
                            .push(MaterialPageRoute<void>(builder: (_) => const SessionExportPage(sessionId: 's1'))),
                    child: const Text('SYNTHETIC open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('SYNTHETIC open'));
        await pumpFrames(tester, 8);
        final pageState = tester.state(find.byType(SessionExportPage));
        await tester.tap(find.text(share ? appL10n.commonShare : appL10n.featuresExportSaveDownloads));
        await tester.pump();
        expect(exporter.calls, [share ? 'share:s1' : 'save:s1']);
        if (leave) {
          Navigator.of(tester.element(find.byType(SessionExportPage))).pop();
          await pumpFrames(tester, 8);
          expect(find.byType(SessionExportPage), findsNothing);
          expect(pageState.mounted, isFalse, reason: 'the failure must arrive after actual disposal');
        }
        exporter.pending.completeError(StateError('SYNTHETIC export failure'));
        await pumpFrames(tester, 8);
        expect(exporter.completed, 1, reason: 'the controlled exporter must actually deliver its failure');
        expect(tester.takeException(), isNull);
        expect(find.text(appL10n.stateExportFailed), leave ? findsNothing : findsOneWidget);
        expect(find.byType(SnackBar), leave ? findsNothing : findsOneWidget);
        if (!leave) expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, const Duration(seconds: 4));
      });
    }
  }
}
