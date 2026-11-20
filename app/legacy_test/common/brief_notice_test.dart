import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart';
import 'package:dsh_app/ui/chat/widgets/message_actions.dart';
import 'package:dsh_app/ui/common/brief_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _step = Duration(milliseconds: 10);

/// A page whose one button runs [onTap] with a context under the messenger.
Future<void> _pumpPage(WidgetTester tester, void Function(BuildContext) onTap, {VoidCallback? onUnderNotice}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Stack(
              children: [
                Center(
                  child: TextButton(onPressed: () => onTap(context), child: const Text('go')),
                ),
                if (onUnderNotice != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 48,
                    child: TextButton(onPressed: onUnderNotice, child: const Text('under notice')),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Taps the button and follows the SnackBar it brings up: how long it stood
/// fully shown (enter and exit animation not counted) and how long it was
/// on screen at all. Null [shown] when it was still up after [limit].
Future<({String text, Duration? shown, Duration total})> _measure(
  WidgetTester tester, {
  Duration limit = const Duration(seconds: 12),
}) async {
  await tester.tap(find.text('go'));
  // Whatever the tap awaits (a platform channel) lands within a few frames.
  for (var i = 0; i < 5 && find.byType(SnackBar).evaluate().isEmpty; i++) {
    await tester.pump();
  }
  expect(find.byType(SnackBar), findsOneWidget);
  final bar = tester.widget<SnackBar>(find.byType(SnackBar));
  final text = tester.widget<Text>(find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).first).data!;
  final animation = bar.animation!;
  var elapsed = Duration.zero;
  Duration? up;
  Duration? down;
  while (find.byType(SnackBar).evaluate().isNotEmpty && elapsed < limit) {
    await tester.pump(_step);
    elapsed += _step;
    if (up == null && animation.status == AnimationStatus.completed) up = elapsed;
    if (up != null && down == null && animation.status == AnimationStatus.reverse) down = elapsed;
  }
  return (text: text, shown: down == null ? null : down - up!, total: elapsed);
}

void main() {
  test('a short confirmation gets the brief duration; longer text a little more, capped', () {
    expect(briefNoticeDuration('已复制'), kBriefNoticeDuration);
    expect(briefNoticeDuration('Copied'), kBriefNoticeDuration);
    expect(kBriefNoticeDuration, const Duration(seconds: 1));
    expect(kBriefNoticeMaxDuration, const Duration(seconds: 2));

    final path = briefNoticeDuration('已存到 下载/dsh-session-20261025-1530.md');
    expect(path, greaterThan(kBriefNoticeDuration));
    expect(path, lessThanOrEqualTo(kBriefNoticeMaxDuration));
    expect(briefNoticeDuration('已复制' * 40), kBriefNoticeMaxDuration);
  });

  testWidgets('「已复制」 stands 1 s, against 4 s for a plain SnackBar', (tester) async {
    await _pumpPage(tester, (context) => showBriefNotice(context, '已复制'));
    final brief = await _measure(tester);
    expect(brief.shown, isNotNull);
    expect(brief.shown!, greaterThanOrEqualTo(kBriefNoticeDuration));
    expect(brief.shown!, lessThanOrEqualTo(kBriefNoticeDuration + _step * 2));

    await _pumpPage(tester, (context) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存失败')));
    });
    final plain = await _measure(tester);
    expect(plain.shown!, greaterThanOrEqualTo(const Duration(seconds: 4)));
    expect(brief.total, lessThan(plain.total - const Duration(seconds: 2)));
  });

  for (final edge in [false, true]) {
    testWidgets('a brief notice dismisses immediately when tapping ${edge ? 'its padding' : 'its text'}', (
      tester,
    ) async {
      await _pumpPage(tester, (context) => showBriefNotice(context, '已复制'));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      if (edge) {
        final card = find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first;
        await tester.tapAt(tester.getRect(card).bottomRight - const Offset(2, 2));
      } else {
        await tester.tap(find.text('已复制'));
      }
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('dismissing a notice does not tap through to the control underneath', (tester) async {
    var taps = 0;
    await _pumpPage(tester, (context) => showBriefNotice(context, '已复制'), onUnderNotice: () => taps++);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已复制'));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(taps, 0);
    await tester.tap(find.text('under notice'));
    expect(taps, 1);
  });

  testWidgets('tapping a plain error does not apply brief-notice dismissal', (tester) async {
    await _pumpPage(tester, (context) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存失败')));
    });
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存失败'));
    await tester.pump();
    expect(find.text('保存失败'), findsOneWidget);
  });

  testWidgets('copying a message confirms briefly', (tester) async {
    await _pumpPage(tester, (context) => copyMessage(context, 'hello'));
    final copied = await _measure(tester);
    expect(copied.text, appL10n.commonCopied);
    expect(copied.shown!, lessThanOrEqualTo(kBriefNoticeDuration + _step * 2));
  });

  testWidgets('repeated message copies do not queue confirmation notices', (tester) async {
    await _pumpPage(tester, (context) => copyMessage(context, 'hello'));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.commonCopied), findsOneWidget);
    await tester.tap(find.text('go'));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a notice with a button leaves at its written time, not the brief one', (tester) async {
    await _pumpPage(tester, (context) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已卸载，重启后生效'),
          duration: const Duration(seconds: 6),
          persist: false,
          action: SnackBarAction(label: '立即重启', onPressed: () {}),
        ),
      );
    });
    final restart = await _measure(tester);
    expect(restart.shown, isNotNull, reason: 'it must not stay up for good');
    expect(restart.shown!, greaterThanOrEqualTo(const Duration(seconds: 6)));
    expect(restart.shown!, lessThanOrEqualTo(const Duration(seconds: 6) + _step * 2));
  });

  testWidgets('refused storage: 「去设置」 stays the default 4 s, then goes', (tester) async {
    const media = MethodChannel('dsh/media');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      media,
      (_) async => throw PlatformException(code: 'permission'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(media, null));
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    await _pumpPage(tester, (context) => saveImageToGallery(context, () async => png, name: 'chart.png'));
    final refused = await _measure(tester);
    expect(refused.text, appL10n.chatImageStorageDenied);
    expect(refused.shown, isNotNull, reason: 'it must not stay up for good');
    expect(refused.shown!, greaterThanOrEqualTo(const Duration(seconds: 4)));
    expect(refused.shown!, lessThanOrEqualTo(const Duration(seconds: 4) + _step * 2));
  });

  test('every notice with a button says whether it stays (persist)', () {
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path;
      if (!path.endsWith('.dart')) continue;
      final src = file.readAsStringSync();
      for (final m in 'SnackBarAction('.allMatches(src)) {
        final start = src.lastIndexOf(RegExp(r'SnackBar\('), m.start);
        if (start >= 0 && src.substring(start, m.start).contains('persist:')) continue;
        missing.add('$path:${'\n'.allMatches(src.substring(0, m.start)).length + 1}');
      }
    }
    expect(missing, isEmpty);
  });

  testWidgets('an undo notice replaces whatever is up or queued at once and stands its window', (tester) async {
    var undone = 0;
    await _pumpPage(tester, (context) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(const SnackBar(content: Text('earlier')));
      messenger.showSnackBar(const SnackBar(content: Text('queued')));
      messenger.showUndoNotice(
        '已归档「A」',
        undoLabel: '撤销',
        onUndo: () => undone++,
        window: const Duration(seconds: 4),
      );
    });
    final undo = await _measure(tester);
    expect(undo.text, '已归档「A」');
    expect(undo.shown!, greaterThanOrEqualTo(const Duration(seconds: 4)));
    expect(undo.shown!, lessThanOrEqualTo(const Duration(seconds: 4) + _step * 2));
    expect(find.text('queued'), findsNothing, reason: 'nothing queued behind it comes back');
    expect(undone, 0);
  });

  testWidgets('a second confirmation replaces the first instead of queueing', (tester) async {
    await _pumpPage(tester, (context) => showBriefNotice(context, '已复制'));
    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('go'));
    await tester.pump();
    // Queued, the two would take about 4 s; replaced, the first leaves at once.
    for (var t = Duration.zero; t < const Duration(milliseconds: 2700); t += _step) {
      await tester.pump(_step);
    }
    expect(find.byType(SnackBar), findsNothing);
  });
}
