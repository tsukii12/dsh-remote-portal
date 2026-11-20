import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_import.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/state/launch_screen_state.dart';
import 'package:dsh_app/ui/settings/appearance/launch_screen_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

class _HeldImport extends LaunchImport {
  final reply = Completer<(CustomLaunch?, LaunchImportProblem?)>();
  int started = 0;
  bool finished = false;

  @override
  Future<(CustomLaunch?, LaunchImportProblem?)> pick({CustomLaunch? previous}) async {
    started++;
    try {
      return await reply.future;
    } finally {
      finished = true;
    }
  }
}

class _Launcher extends LauncherIconChannel {
  const _Launcher();

  @override
  Future<AppIconState?> state() async => const AppIconState(current: AppIcon.mist);
}

void main() {
  for (final success in [false, true]) {
    testWidgets('launch selection ${success ? 'success' : 'cancellation'} after page pop is owned', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('launch-late-result-');
      final image = File('${directory.path}/selected.png')
        ..writeAsBytesSync(
          base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII='),
        );
      final custom = CustomLaunch(kind: LaunchMediaKind.image, path: image.path, width: 1, height: 1);
      final importer = _HeldImport();
      ProviderContainer? container;
      try {
        await tester.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            overrides: [
              launchImportProvider.overrideWithValue(importer),
              launcherIconChannelProvider.overrideWithValue(const _Launcher()),
            ],
            home: Builder(
              builder: (context) {
                container = ProviderScope.containerOf(context, listen: false);
                return Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Launch settings')),
                          body: const SingleChildScrollView(child: LaunchScreenSection()),
                        ),
                      ),
                    ),
                    child: const Text('Open launch settings'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open launch settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('launch-custom')));
        await tester.pump();
        expect(importer.started, 1, reason: 'the real section action must own the pending import');
        expect(importer.finished, false);

        // Pop only the settings route. The App scope and real controller survive.
        final back = find.byType(BackButton);
        expect(back, findsOneWidget);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byType(LaunchScreenSection), findsNothing);
        expect(importer.finished, false);
        expect(tester.takeException(), isNull);

        importer.reply.complete(success ? (custom, null) : (null, LaunchImportProblem.cancelled));
        await tester.pumpAndSettle();
        expect(importer.finished, true);
        expect(tester.takeException(), isNull, reason: 'late completion must not read a disposed widget ref');
        expect(container!.read(customLaunchProvider).value?.path, success ? image.path : null);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(CustomLaunch.prefsKey), success ? contains(image.path) : isNull);
      } finally {
        // Release the input even when a preceding assertion fails; no predicted
        // native-success gate or timeout is needed to join this real seam.
        if (!importer.reply.isCompleted) importer.reply.complete((null, LaunchImportProblem.cancelled));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        directory.deleteSync(recursive: true);
      }
    });
  }
}
