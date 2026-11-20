// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/image_gen/image_generation.dart';
import 'package:dsh_app/ui/fx/image_gen/renderer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves an already-decoded picture synchronously, so fake-async tests can reveal it.
class _TestImage extends ImageProvider<_TestImage> {
  const _TestImage(this.image, this.name);

  final ui.Image image;
  final String name;

  @override
  Future<_TestImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_TestImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));

  @override
  bool operator ==(Object other) => other is _TestImage && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A picture whose decode finishes when the test says so.
class _LateImage extends ImageProvider<_LateImage> {
  _LateImage(this.name);

  final String name;
  final decoded = Completer<ImageInfo>();

  @override
  Future<_LateImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_LateImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(decoded.future);

  @override
  bool operator ==(Object other) => other is _LateImage && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(size: const Size(400, 800), disableAnimations: reduced),
    child: Center(child: SizedBox(width: 280, height: 210, child: child)),
  ),
);

void main() {
  setUp(() {
    ImageGeneration.debugSeed = 7;
    imageCache.clear();
  });
  tearDown(() => ImageGeneration.debugSeed = null);

  testWidgets('mosaic, reveal, regenerate, next image, hide', (tester) async {
    final a = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    final b = (await tester.runAsync(() => createTestImage(width: 48, height: 64)))!;
    final phases = <ImageGenerationPhase>[];
    Future<void> show(ImageProvider? image, {bool generating = false}) async {
      await tester.pumpWidget(
        _host(
          ImageGeneration(
            image: image,
            generating: generating,
            onPhase: phases.add,
            child: const Center(child: Text('生成中 · 42%')),
          ),
        ),
      );
    }

    await show(null, generating: true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('生成中 · 42%'), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);

    await show(_TestImage(a, 'a'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(phases, [ImageGenerationPhase.reveal]);
    // The reveal runs three seconds, then the image holds and the ticker stops.
    for (var i = 0; i < 32; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(phases.last, ImageGenerationPhase.visible);
    expect(tester.hasRunningAnimations, isFalse);

    // Regenerate: the shown image breaks into the churn until the next one lands.
    await show(_TestImage(a, 'a'), generating: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(phases.last, ImageGenerationPhase.idle);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.hasRunningAnimations, isTrue);

    await show(_TestImage(b, 'b'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(phases.sublist(phases.length - 2), [ImageGenerationPhase.reveal, ImageGenerationPhase.visible]);

    await show(null);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(phases.sublist(phases.length - 2), [ImageGenerationPhase.hide, ImageGenerationPhase.idle]);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    a.dispose();
    b.dispose();
  });

  testWidgets('a new image over a shown one churns into it', (tester) async {
    final a = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    final b = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    final phases = <ImageGenerationPhase>[];
    for (final image in [_TestImage(a, 'a'), _TestImage(b, 'b')]) {
      await tester.pumpWidget(
        _host(ImageGeneration(image: image, preset: ImageGenerationPreset.sweepGradient, onPhase: phases.add)),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(phases, [
      ImageGenerationPhase.reveal,
      ImageGenerationPhase.visible,
      ImageGenerationPhase.idle,
      ImageGenerationPhase.reveal,
      ImageGenerationPhase.visible,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
    b.dispose();
  });

  testWidgets('without fragment programs the CPU path draws the same flow', (tester) async {
    // Not awaited: an earlier test's fake zone may own the cached future.
    FxPrograms.load().ignore();
    await tester.pump();
    final programs = FxPrograms.ready;
    FxPrograms.ready = null;
    addTearDown(() => FxPrograms.ready = programs);
    final a = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    final phases = <ImageGenerationPhase>[];
    for (final preset in ImageGenerationPreset.values) {
      phases.clear();
      await tester.pumpWidget(_host(ImageGeneration(key: ValueKey(preset), preset: preset, onPhase: phases.add)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(
        _host(ImageGeneration(key: ValueKey(preset), preset: preset, image: _TestImage(a, 'a'), onPhase: phases.add)),
      );
      for (var i = 0; i < 34; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(
        _host(
          ImageGeneration(
            key: ValueKey(preset),
            preset: preset,
            image: _TestImage(a, 'a'),
            generating: true,
            onPhase: phases.add,
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(phases, [ImageGenerationPhase.reveal, ImageGenerationPhase.visible, ImageGenerationPhase.idle]);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
  });

  testWidgets('reduced motion: a still mosaic, then the image at once', (tester) async {
    final a = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    for (final preset in ImageGenerationPreset.values) {
      await tester.pumpWidget(_host(ImageGeneration(preset: preset), reduced: true));
      expect(tester.hasRunningAnimations, isFalse);
    }
    final phases = <ImageGenerationPhase>[];
    await tester.pumpWidget(_host(ImageGeneration(image: _TestImage(a, 'a'), onPhase: phases.add), reduced: true));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(phases, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
  });

  testWidgets('reduced motion from the first frame unmounts cleanly', (tester) async {
    await tester.pumpWidget(_host(const ImageGeneration(generating: true), reduced: true));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a decode that lands after generating restarts, or the image went, never shows', (tester) async {
    final a = (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!;
    for (final (i, keep, generating) in [(0, true, true), (1, false, false)]) {
      final late = _LateImage('late$i');
      final phases = <ImageGenerationPhase>[];
      Future<void> show(ImageProvider? image, bool generating) => tester.pumpWidget(
        _host(ImageGeneration(key: ValueKey(i), image: image, generating: generating, onPhase: phases.add)),
      );
      await show(late, false);
      await tester.pump(const Duration(milliseconds: 100));
      await show(keep ? late : null, generating);
      late.decoded.complete(ImageInfo(image: a.clone()));
      for (var f = 0; f < 40; f++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(phases, isEmpty, reason: 'case $i');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
  });

  testWidgets('during a handoff a newer image wins, and clearing it lets later images in', (tester) async {
    final pics = [for (var k = 0; k < 4; k++) (await tester.runAsync(() => createTestImage(width: 64, height: 48)))!];
    final phases = <ImageGenerationPhase>[];
    Future<void> show(ImageProvider? image, {bool generating = false}) =>
        tester.pumpWidget(_host(ImageGeneration(image: image, generating: generating, onPhase: phases.add)));
    Future<void> frames(int n) async {
      for (var f = 0; f < n; f++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final a = _TestImage(pics[0], 'a'), b = _TestImage(pics[1], 'b');
    final c = _TestImage(pics[2], 'c'), d = _TestImage(pics[3], 'd');
    await show(a);
    await frames(34);
    await show(a, generating: true);
    await frames(10);
    phases.clear();
    // b starts dissolving in over the churn; c arrives before it settles.
    await show(b);
    await frames(1);
    await show(c);
    await frames(40);
    expect(phases, [ImageGenerationPhase.reveal, ImageGenerationPhase.reveal, ImageGenerationPhase.visible]);

    await show(c, generating: true);
    await frames(10);
    await show(d);
    await frames(1);
    // Cleared mid-handoff: the churn fades out, and the next picture still comes in.
    await show(null);
    await frames(6);
    await show(b);
    await frames(40);
    expect(phases.sublist(phases.length - 2), [ImageGenerationPhase.reveal, ImageGenerationPhase.visible]);
    expect(phases, contains(ImageGenerationPhase.hide));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    for (final p in pics) {
      p.dispose();
    }
  });
}
