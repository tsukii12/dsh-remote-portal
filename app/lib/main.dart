import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'dev/remote_benchmark.dart';
import 'diagnostics/app_error_log.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/fx/metal/metal_shader.dart';
import 'ui/fx/waves/distortion_wave.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() {
  RemoteBenchmark.start('startup');
  RemoteBenchmark.start('first_paint');
  return runWithFrameProbe(_startApp);
}

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
  if (RemoteBenchmark.enabled) {
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) => RemoteBenchmark.finish('first_paint')));
  }
  appErrorCapture.install();
  await AppLanguageController.load();
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // The effects' shaders load now, so the first wave or metal word is not a plain fallback.
  unawaited(DistortionWave.precache());
  unawaited(MetalShader.load());
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  RemoteBenchmark.finish('startup');
  runApp(const ProviderScope(child: DshApp()));
}
