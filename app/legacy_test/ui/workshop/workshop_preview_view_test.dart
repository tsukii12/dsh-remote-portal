// The public picture of a workshop item (ui/workshop/workshop_widgets.dart):
// where its address comes from, how each kind is drawn, and that a missing
// or failed picture leaves the letter square and nothing else changes.

import 'dart:io';

import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart' show PluginAvatar;
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workshop/workshop_widgets.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/workshop_page_samples.dart';
import '../../workshop/support.dart';

/// A client that knows its origin and is never asked for anything.
WorkshopClient _client() => WorkshopClient(
  origin: workshopTestOrigin,
  cacheFile: File('${Directory.systemTemp.path}/workshop-preview-view-unused.json'),
  http: FakeWorkshopHttp((method, url, headers, body) => throw StateError('no request expected')),
);

Future<void> _pump(WidgetTester tester, Widget child, {WorkshopClient? client, bool ready = true}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workshopClientProvider.overrideWith((ref) async {
          if (!ready) throw const WorkshopException('workshop_unconfigured');
          return client ?? _client();
        }),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
  // The client arrives, then the test binding's HTTP answers 400 for the picture.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

String _expectedUrl(WorkshopEntry entry) => '$workshopTestOrigin${entry.preview!.path}';

void main() {
  testWidgets('a pet with a picture: its address is the data layer\'s, drawn with hard edges', (tester) async {
    final entry = workshopSamplePreviewEntry();
    await _pump(tester, WorkshopEntryAvatar(entry, size: 64));

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).url, _expectedUrl(entry));
    expect(image.filterQuality, FilterQuality.none);
    expect(image.fit, BoxFit.contain);
    expect(tester.getSize(find.byType(WorkshopEntryAvatar)), const Size(64, 64));
  });

  testWidgets('a companion with a cover: smoothed, filling the square, decoded no larger than shown', (tester) async {
    final entry = workshopSamplePreviewEntry(kind: 'companion');
    await _pump(tester, WorkshopEntryAvatar(entry));

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    expect(((provider as ResizeImage).imageProvider as NetworkImage).url, _expectedUrl(entry));
    expect(image.filterQuality, FilterQuality.medium);
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('a picture that cannot be had leaves the letter square, and raises nothing', (tester) async {
    await _pump(tester, WorkshopEntryAvatar(workshopSamplePreviewEntry()));

    expect(find.byType(PluginAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no picture for this release: the letter square, and no image is asked for', (tester) async {
    await _pump(tester, WorkshopEntryAvatar(workshopSampleEntry()));

    expect(find.byType(Image), findsNothing);
    expect(find.byType(PluginAvatar), findsOneWidget);
  });

  testWidgets('the workshop is not ready to say where pictures are: the letter square', (tester) async {
    await _pump(tester, WorkshopEntryAvatar(workshopSamplePreviewEntry()), ready: false);

    expect(find.byType(Image), findsNothing);
    expect(find.byType(PluginAvatar), findsOneWidget);
  });

  testWidgets('a detail picture that cannot be had shows the letter square, not an empty frame', (tester) async {
    await _pump(tester, WorkshopPreviewPanel(workshopSamplePreviewEntry()));

    expect(find.byType(PluginAvatar), findsOneWidget);
    expect(tester.getSize(find.byType(PluginAvatar)), const Size(72, 72));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the detail panel shows the picture at a size to judge it by, or is not there at all', (tester) async {
    final entry = workshopSamplePreviewEntry();
    await _pump(tester, WorkshopPreviewPanel(entry));
    expect((tester.widget<Image>(find.byType(Image)).image as NetworkImage).url, _expectedUrl(entry));
    expect(tester.getSize(find.byType(WorkshopPreviewPanel)).height, greaterThan(100));

    await _pump(tester, WorkshopPreviewPanel(workshopSampleEntry()));
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(WorkshopPreviewPanel)), Size.zero);
  });
}
