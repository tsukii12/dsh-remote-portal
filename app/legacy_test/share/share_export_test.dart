// The export waits for the card's pictures: a capture started while a
// picture is still on its way finishes only once it is drawn, and a picture
// that never comes is given up on after the timeout rather than holding the
// export.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A picture whose bytes arrive when [gate] completes.
class _GatedImage extends ImageProvider<_GatedImage> {
  _GatedImage(this.gate, this.bytes);

  final Completer<void> gate;
  final Uint8List bytes;

  @override
  Future<_GatedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_GatedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(() async {
        await gate.future;
        final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
        return ImageInfo(image: (await codec.getNextFrame()).image);
      }());
}

Future<void> _drainUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  testWidgets('a capture waits for a picture still on its way', (tester) async {
    final bytes = (await tester.runAsync(() => samplePhoto(400, 300)))!;
    final gate = Completer<void>();
    final key = GlobalKey();
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          title: '图',
          blocks: [
            ShareQuestion('看看', images: [ShareProvidedImage(_GatedImage(gate, bytes))]),
          ],
        ),
      ),
      boundary: key,
      settle: false,
    );
    Uint8List? png;
    final capture = captureShareCard(key).then((value) => png = value);
    await _drainUntil(tester, () => false);
    expect(png, isNull, reason: 'the picture has not come yet');
    expect(find.byType(RawImage), findsNothing);

    gate.complete();
    await _drainUntil(tester, () => png != null);
    await capture;
    expect(png, isNotNull);
    expect(find.byType(RawImage), findsOneWidget, reason: 'drawn before the capture');
  });

  testWidgets('a picture that never comes does not hold the export', (tester) async {
    final gate = Completer<void>();
    final key = GlobalKey();
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          blocks: [
            ShareQuestion('看看', images: [ShareProvidedImage(_GatedImage(gate, Uint8List(0)))]),
          ],
        ),
      ),
      boundary: key,
      settle: false,
    );
    Uint8List? png;
    unawaited(captureShareCard(key, imageTimeout: const Duration(seconds: 2)).then((value) => png = value));
    await tester.pump(const Duration(seconds: 3));
    await _drainUntil(tester, () => png != null);
    expect(png, isNotNull);
  });
}
