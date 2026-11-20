// The launcher-shortcut and Quick Settings icons, measured from the
// resources that ship: every glyph centred on the adaptive canvas and inside
// the launcher's safe zone, left and right insets equal, the tile glyph inside
// Material's live area. Plus the wiring the launcher depends on and nothing
// checks at build time: shortcut actions, classes, package, labels, icons,
// and the limits the Dart and Kotlin sides share.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/vector_drawable.dart';

const _kotlin = 'android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app';

String _source(String relative) => File('$_kotlin/$relative').readAsStringSync();

/// `const val NAME = <value>` in a Kotlin file.
String _constant(String source, String name) {
  final m = RegExp('const val $name = ([^\\n]+)').firstMatch(source);
  expect(m, isNotNull, reason: '$name not found');
  return m!.group(1)!.trim().replaceAll('"', '');
}

/// `1L * 1024 * 1024` style Kotlin constants.
int _bytes(String expression) =>
    expression.replaceAll('L', '').split('*').map((p) => int.parse(p.trim())).reduce((a, b) => a * b);

void main() {
  const glyphs = ['ic_shortcut_new_chat_glyph', 'ic_shortcut_voice_glyph', 'ic_shortcut_chat_glyph'];

  group('shortcut glyphs', () {
    for (final name in glyphs) {
      test('$name is centred, sized and inside the safe zone', () {
        final glyph = VectorGlyph.load(name);
        expect(glyph.viewport, const Size(108, 108));
        // The 24-unit Material box: 40dp, centred on the 108dp canvas.
        expect(glyph.iconBox.width, closeTo(40, 0.01));
        expect(glyph.iconBox.center.dx, closeTo(54, 0.01));
        expect(glyph.iconBox.center.dy, closeTo(54, 0.01));
        // Launchers mask to the middle 72dp; the 66dp circle is always shown.
        const centre = Offset(54, 54);
        for (final p in glyph.points) {
          expect((p - centre).distance, lessThan(33), reason: '$p');
        }
        // Equal side insets (the drawn outline, not just its box).
        final b = glyph.bounds;
        expect(b.left - 34, closeTo(74 - b.right, 0.1));
        expect(glyph.fill, '@color/shortcut_icon_glyph');
      });
    }

    test('each adaptive icon layers its glyph over the container tone', () {
      for (final name in ['new_chat', 'voice', 'chat']) {
        final xml = readRes('drawable/ic_shortcut_$name.xml');
        expect(xml, contains('<adaptive-icon'));
        expect(xml, contains('<background android:drawable="@color/shortcut_icon_background" />'));
        expect(xml, contains('<foreground android:drawable="@drawable/ic_shortcut_${name}_glyph" />'));
        expect(xml, contains('<monochrome android:drawable="@drawable/ic_shortcut_${name}_glyph" />'));
      }
    });

    test('glyph and background contrast in both launcher themes', () {
      double luminance(Color c) => c.computeLuminance();
      for (final dark in [false, true]) {
        final bg = resolveColor('@color/shortcut_icon_background', dark: dark);
        final fg = resolveColor('@color/shortcut_icon_glyph', dark: dark);
        final hi = math.max(luminance(bg), luminance(fg));
        final lo = math.min(luminance(bg), luminance(fg));
        // Icons are graphics: WCAG's 3:1 for non-text contrast.
        expect((hi + 0.05) / (lo + 0.05), greaterThan(3), reason: 'dark: $dark');
      }
    });
  });

  test('the tile glyph sits in the 24dp icon live area, centred', () {
    final glyph = VectorGlyph.load('ic_tile_new_chat');
    expect(glyph.viewport, const Size(24, 24));
    final b = glyph.bounds;
    expect(b.left, greaterThanOrEqualTo(2 - 0.05));
    expect(b.top, greaterThanOrEqualTo(2 - 0.05));
    expect(b.right, lessThanOrEqualTo(22 + 0.05));
    expect(b.bottom, lessThanOrEqualTo(22 + 0.05));
    expect(b.left, closeTo(24 - b.right, 0.1));
    // Same outline as the 新对话 shortcut.
    expect(glyph.pathData, VectorGlyph.load('ic_shortcut_new_chat_glyph').pathData);
  });

  group('static shortcuts', () {
    final xml = readRes('xml/shortcuts.xml');
    final entry = _source('shortcuts/EntryActivity.kt');
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final applicationId = RegExp(r'applicationId = "([^"]+)"').firstMatch(gradle)!.group(1)!;
    final strings = readRes('values-zh/entry_strings.xml');

    final shortcuts = RegExp(r'<shortcut\b([\s\S]*?)</shortcut>').allMatches(xml).map((m) => m.group(1)!).toList();

    String attr(String block, String name) => RegExp('android:$name="([^"]+)"').firstMatch(block)!.group(1)!;

    test('新对话 then 语音输入, with their labels and icons', () {
      expect(shortcuts.map((s) => attr(s, 'shortcutId')), ['new_chat', 'voice_input']);
      final labels = {
        for (final m in RegExp(r'<string name="([^"]+)">([^<]+)</string>').allMatches(strings))
          m.group(1)!: m.group(2)!,
      };
      expect(
        [for (final s in shortcuts) labels[attr(s, 'shortcutShortLabel').replaceFirst('@string/', '')]],
        ['新对话', '语音输入'],
      );
      for (final s in shortcuts) {
        final icon = attr(s, 'icon').replaceFirst('@drawable/', '');
        expect(File('$resDir/drawable/$icon.xml').existsSync(), isTrue, reason: icon);
      }
      expect(labels['tile_new_chat'], '新对话');
      // English is the default resource set (values/), Chinese values-zh/.
      expect(readRes('values/entry_strings.xml'), contains('<string name="shortcut_new_chat">New chat</string>'));
    });

    test('point at EntryActivity with the actions it knows', () {
      expect(
        [for (final s in shortcuts) attr(s, 'action')],
        [_constant(entry, 'ACTION_NEW_CHAT'), _constant(entry, 'ACTION_VOICE')],
      );
      for (final s in shortcuts) {
        expect(attr(s, 'targetPackage'), applicationId);
        expect(attr(s, 'targetClass'), '$applicationId.shortcuts.EntryActivity');
      }
    });
  });

  test('limits agree between Dart and Kotlin', () {
    final share = _source('share/SharePlugin.kt');
    final shortcuts = _source('shortcuts/ShortcutsPlugin.kt');
    expect(int.parse(_constant(share, 'MAX_ITEMS')), maxAttachments);
    expect(_bytes(_constant(share, 'MAX_FILE_BYTES')), maxFileBytes);
    expect(_bytes(_constant(share, 'MAX_TOTAL_BYTES')), maxMessageBytes);
    expect(int.parse(_constant(shortcuts, 'MAX_RECENT')), maxRecentShortcuts);
  });
}
