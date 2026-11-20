// Not a check: renders every preset in light and dark (chat, settings,
// drawer) and lays them out side by side for review. Skipped unless asked:
//
//   DSH_PALETTE_PREVIEW=<out dir> flutter test test/theme/palette_preview_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/sessions_state.dart' as sessions;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show ChatHarness;
import '../chat/support/sample_chat.dart';
import '../shell/golden_harness.dart';
import '../support/test_fonts.dart';

final _out = Platform.environment['DSH_PALETTE_PREVIEW'];

class _Fixed extends AppearanceController {
  _Fixed(this.id);

  final String id;

  @override
  AppearanceSettings build() => AppearanceSettings(presetId: id, loaded: true);
}

/// A microphone that never answers: the chat's capability probe stays
/// pending instead of landing after the screen is gone.
class _QuietVoice implements VoiceBridge {
  @override
  Future<VoiceCapabilities> capabilities() => Completer<VoiceCapabilities>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stand-in behind the open drawer: the page itself.
class _Behind extends StatelessWidget {
  const _Behind();

  @override
  Widget build(BuildContext context) => const AppBackdrop(child: SizedBox.expand());
}

Widget _app(Widget home, AppAccent accent, Brightness brightness, List<Override> overrides) => ProviderScope(
  overrides: [
    onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
    drawerClockProvider.overrideWithValue(() => sampleNow),
    appearanceProvider.overrideWith(() => _Fixed(accent.id)),
    ...overrides,
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme(accent: accent)),
    darkTheme: withTestFonts(buildDarkTheme(accent: accent)),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
    home: home,
  ),
);

Future<ui.Image> _shoot(WidgetTester tester) async {
  await tester.pump();
  late ui.Image image;
  await tester.runAsync(() async {
    final view = RendererBinding.instance.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    image = await layer.toImage(view.paintBounds, pixelRatio: 1);
  });
  return image;
}

void main() {
  testWidgets('palette preview sheet', skip: _out == null, (tester) async {
    // Stored preferences answer at once, so nothing lands after a screen is gone.
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(loadTestFonts);
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
    runClock = () => DateTime(2026, 10, 23, 15, 20);
    usePhoneSurface(tester);

    final screens = <String, Widget Function()>{
      '聊天': () => const ChatScreen(),
      '设置': () => const SettingsScreen(),
      '抽屉': () => const HomeShell(chatBuilder: _behindBuilder, initiallyOpen: true),
    };
    final shots = <(AppAccent, Brightness, String), ui.Image>{};
    for (final accent in AppAccent.presets) {
      for (final brightness in Brightness.values) {
        for (final MapEntry(key: name, value: screen) in screens.entries) {
          final overrides = <Override>[
            accountWalletBalanceProvider.overrideWithValue(null),
            if (name == '聊天') ...[
              ...ChatHarness(session: 's1', states: {'s1': conversationState()}).overrides,
              voiceBridgeProvider.overrideWithValue(_QuietVoice()),
            ] else ...[
              localConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
              localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
              settingsProvider.overrideWith(
                () => FakeSettings(const AppSettings(loaded: true, apiKey: 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9')),
              ),
              sessions.sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
              sessions.currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
            ],
          ];
          await tester.pumpWidget(_app(screen(), accent, brightness, overrides));
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          shots[(accent, brightness, name)] = await _shoot(tester);
          await tester.pumpWidget(const SizedBox());
        }
      }
    }

    await tester.runAsync(() async {
      Directory(_out!).createSync(recursive: true);
      await _sheet(shots, screens.keys.toList(), scale: 0.5, file: '$_out/palettes_overview.png');
      for (final accent in AppAccent.presets) {
        await _sheet(
          {
            for (final e in shots.entries)
              if (e.key.$1 == accent) e.key: e.value,
          },
          screens.keys.toList(),
          scale: 1,
          file: '$_out/palette_${accent.id}.png',
          only: accent,
        );
      }
    });
  });
}

Widget _behindBuilder(VoidCallback openDrawer) => const _Behind();

/// Rows = palettes, columns = screens (light, then dark).
Future<void> _sheet(
  Map<(AppAccent, Brightness, String), ui.Image> shots,
  List<String> screens, {
  required double scale,
  required String file,
  AppAccent? only,
}) async {
  const gap = 12.0;
  const label = 132.0;
  const header = 56.0;
  final cellW = 390 * scale;
  final cellH = 844 * scale;
  final rows = only == null ? AppAccent.presets : [only];
  final cols = [
    for (final b in Brightness.values.reversed)
      for (final s in screens) (b, s),
  ];
  final width = label + cols.length * (cellW + gap) + gap;
  final height = header + rows.length * (cellH + gap) + gap;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = const Color(0xFF0E0F12));

  void text(String s, Offset at, {double size = 14, Color color = const Color(0xFFE6E8EC), double w = 400}) {
    final b =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontFamily: sansFamily, fontSize: size, fontWeight: w >= 600 ? FontWeight.w600 : null),
          )
          ..pushStyle(ui.TextStyle(color: color, fontFamily: sansFamily, fontFamilyFallback: const [cjkFamily]))
          ..addText(s);
    final p = b.build()..layout(ui.ParagraphConstraints(width: width));
    canvas.drawParagraph(p, at);
  }

  for (final (i, (b, s)) in cols.indexed) {
    text('$s · ${b == Brightness.light ? '浅色' : '深色'}', Offset(label + gap + i * (cellW + gap), 20), size: 15);
  }
  for (final (r, accent) in rows.indexed) {
    final top = header + r * (cellH + gap);
    text(accent.label, Offset(16, top + 8), size: 22, w: 600);
    canvas.drawCircle(Offset(26, top + 56), 10, Paint()..color = accent.seed);
    canvas.drawCircle(Offset(52, top + 56), 10, Paint()..color = accent.seedDark);
    text(_hex(accent.seed), Offset(16, top + 76), size: 12, color: const Color(0xFF9DA2AB));
    text(_hex(accent.seedDark), Offset(16, top + 94), size: 12, color: const Color(0xFF9DA2AB));
    for (final (c, (b, s)) in cols.indexed) {
      final image = shots[(accent, b, s)]!;
      final dst = Rect.fromLTWH(label + gap + c * (cellW + gap), top, cellW, cellH);
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(dst, Radius.circular(18 * scale)));
      canvas.drawImageRect(
        image,
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
  }
  final image = await recorder.endRecording().toImage(width.ceil(), height.ceil());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(file).writeAsBytesSync(png!.buffer.asUint8List());
}

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
