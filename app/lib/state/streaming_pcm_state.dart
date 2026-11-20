import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../voice/streaming_pcm.dart';

final streamingPcmCaptureProvider = Provider<StreamingPcmCapture>((ref) {
  final capture = StreamingPcmCapture();
  ref.onDispose(() => unawaited(capture.dispose()));
  return capture;
});
