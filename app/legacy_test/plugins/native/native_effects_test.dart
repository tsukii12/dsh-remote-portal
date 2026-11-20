// The effect whitelist (protocol §5) and the 3 s window (§4.4): what a
// plugin may ask for, in either written form, and when it may still run.

import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:flutter_test/flutter_test.dart';

List<NativeEffect> parse(List<Map<String, Object?>> raw, [List<NativeIssue>? issues]) =>
    parseNativeEffects(raw, issues ?? []);

void main() {
  group('whitelist', () {
    test('native effects cannot select permission presets after name normalization', () {
      for (final name in ['permission', '/permission', ' /permission ']) {
        for (final args in ['', 'read-only', 'workspace-write', 'danger-full-access', 'auto']) {
          for (final raw in [
            {'type': 'command', 'name': name, 'args': args},
            {
              'command': {'name': name, 'args': args},
            },
          ]) {
            final issues = <NativeIssue>[];
            expect(parse([raw], issues), isEmpty);
            expect(issues.single.code, 'bad-effect');
          }
        }
      }
      expect(
        parse([
          {'insert': '/permission read-only'},
        ]).single,
        isA<InsertEffect>(),
      );
    });

    test('canonical and short forms', () {
      final effects = parse([
        {'type': 'insert', 'text': 'Hello'},
        {'insert': '你好'},
        {'type': 'command', 'name': 'compact'},
        {
          'command': {'name': 'compact', 'args': 'summary'},
        },
        {'type': 'open', 'page': 'skills'},
        {'open': 'panel:usage'},
        {'type': 'link', 'url': 'https://example.com/a?b=1'},
        {'toast': '好了'},
        {'copy': 'text'},
        {'refresh': 'usage'},
        {
          'type': 'patch',
          'data': {'n': 1},
        },
      ]);
      expect(effects.map((e) => e.runtimeType), [
        InsertEffect,
        InsertEffect,
        CommandEffect,
        CommandEffect,
        OpenEffect,
        OpenEffect,
        LinkEffect,
        ToastEffect,
        CopyEffect,
        RefreshEffect,
        PatchEffect,
      ]);
      expect((effects[3] as CommandEffect).line, '/compact summary');
      expect((effects[4] as OpenEffect).page, 'skills');
      expect((effects[5] as OpenEffect).panel, 'usage');
      expect((effects[9] as RefreshEffect).panel, 'usage');
    });

    test('nothing outside the list, and no unsafe forms', () {
      final issues = <NativeIssue>[];
      final effects = parse([
        {'type': 'approve', 'id': 'x'},
        {'type': 'send', 'text': 'go'},
        {'type': 'link', 'url': 'http://example.com'},
        {'type': 'link', 'url': 'https://user:pw@example.com'},
        {'type': 'link', 'url': 'javascript:alert(1)'},
        {'type': 'command', 'name': 'rm -rf'},
        {'type': 'open', 'page': 'phone-control-everything'},
        {'type': 'insert'},
        {'type': 'patch', 'data': 'not an object'},
        {'a': 1, 'b': 2},
      ], issues);
      expect(effects, isEmpty);
      expect(issues, hasLength(10));
      expect(issues.first.code, 'unknown-effect');
      expect(issues.map((i) => i.pointer).toSet(), hasLength(10), reason: 'each issue says where');
    });

    test('long texts are cut, a toast to one line of 40', () {
      final issues = <NativeIssue>[];
      final effects = parse([
        {'toast': '第一行\n${'字' * 60}'},
        {'insert': 'x' * 2500},
      ], issues);
      final toast = effects.first as ToastEffect;
      expect(toast.text.contains('\n'), isFalse);
      expect(toast.text.runes.length, NativeLimits.toastMax);
      expect((effects.last as InsertEffect).text.length, 2000);
      expect(issues, hasLength(2));
    });
  });

  group('3 s window', () {
    final tap = DateTime(2026, 10, 25, 12);
    final all = <NativeEffect>[
      const InsertEffect('a'),
      const ToastEffect('b'),
      const PatchEffect({'n': 1}),
      const RefreshEffect(),
    ];

    test('everything runs within 3 s of the tap', () {
      expect(effectsInWindow(all, tappedAt: tap, now: tap.add(const Duration(milliseconds: 2999))), all);
      expect(effectsInWindow(all, tappedAt: tap, now: tap.add(const Duration(seconds: 3))), all);
    });

    test('after it, only data updates; one issue says why', () {
      final issues = <NativeIssue>[];
      final late = effectsInWindow(
        all,
        tappedAt: tap,
        now: tap.add(const Duration(seconds: 3, milliseconds: 1)),
        issues: issues,
      );
      expect(late.map((e) => e.runtimeType), [PatchEffect, RefreshEffect]);
      expect(issues.single.message, '点按 3 秒后才返回，已忽略');
    });

    test('no gesture and a clock rollback both allow only data effects', () {
      for (final sample in [
        (gesture: false, now: tap),
        (gesture: true, now: tap.subtract(const Duration(milliseconds: 1))),
      ]) {
        final issues = <NativeIssue>[];
        final kept = effectsInWindow(all, tappedAt: tap, now: sample.now, userGesture: sample.gesture, issues: issues);
        expect(kept.map((e) => e.runtimeType), [PatchEffect, RefreshEffect]);
        expect(issues, hasLength(1));
      }
      expect(nativeTapIsFresh(tap, tap.add(const Duration(seconds: 3))), isTrue);
      expect(nativeTapIsFresh(tap, tap.add(const Duration(seconds: 3, microseconds: 1))), isFalse);
      expect(nativeTapIsFresh(tap, tap.subtract(const Duration(microseconds: 1))), isFalse);
    });
  });

  test('toasts: one every 2 s per plugin', () {
    final throttle = ToastThrottle();
    final t = DateTime(2026, 10, 25, 12);
    expect(throttle.allow('a', t), isTrue);
    expect(throttle.allow('a', t.add(const Duration(seconds: 1))), isFalse);
    expect(throttle.allow('b', t.add(const Duration(seconds: 1))), isTrue);
    expect(throttle.allow('a', t.add(const Duration(seconds: 2))), isTrue);
  });
}
