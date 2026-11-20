import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workshop_auth_test_support.dart';
import 'workshop_recovery_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a malformed current entry is removed without parsing its paths or changing other scopes', () async {
    final scope = recoveryScope(), other = recoveryScope(userId: 43);
    final pending = recoveryPending(scope: other);
    final raw = jsonEncode({scope: {'directoryName': '../not-a-private-draft'}, other: pending.toJson()});
    final platform = recoveryPlatform({recoveryPendingKey: raw});
    const preferences = PrefsWorkshopPreferences();
    await preferences.acceptDisclosure(authWorker, authAccount);
    await preferences.reserveSubmissionRequestId(pending.fingerprint, pending.requestId);
    final disclosure = await platform.raw(recoveryDisclosuresKey);
    final ids = await platform.raw(recoveryRequestsKey);
    final snapshot = await preferences.pendingRecovery(scope);
    expect(snapshot.range, WorkshopPendingAbandonRange.currentAccount);
    expect(await platform.raw(recoveryPendingKey), raw); // Offering is read-only.
    await preferences.abandonPendingRecovery(snapshot);
    expect(await preferences.pendingSubmission(scope), isNull);
    expect((await preferences.pendingSubmission(other))!.toJson(), pending.toJson());
    expect(await platform.raw(recoveryDisclosuresKey), disclosure);
    expect(await platform.raw(recoveryRequestsKey), ids);
    expect(platform.pendingRemoves, 0);
  });

  for (final raw in <Object>['{', '[]', true, ['broken', 'container']]) {
    test('an unreadable top-level ${raw.runtimeType}:$raw needs the all-local-accounts range', () async {
      final platform = recoveryPlatform({recoveryPendingKey: raw});
      const preferences = PrefsWorkshopPreferences();
      final snapshot = await preferences.pendingRecovery(recoveryScope());
      expect(snapshot.range, WorkshopPendingAbandonRange.allLocalAccounts);
      expect(await platform.raw(recoveryPendingKey), raw);
      await preferences.abandonPendingRecovery(snapshot);
      expect(await platform.raw(recoveryPendingKey), isNull);
      expect(platform.pendingRemoves, 1);
      expect(platform.pendingWrites, 0);
    });
  }

  test('a valid container with no current record is never offered as a whole-container clear', () async {
    final scope = recoveryScope(), other = recoveryScope(userId: 43);
    final raw = jsonEncode({other: null});
    final platform = recoveryPlatform({recoveryPendingKey: raw});
    const preferences = PrefsWorkshopPreferences();
    final snapshot = await preferences.pendingRecovery(scope);
    expect(snapshot.range, WorkshopPendingAbandonRange.currentAccount);
    await preferences.abandonPendingRecovery(snapshot);
    expect(await platform.raw(recoveryPendingKey), raw);
    expect(platform.pendingWrites + platform.pendingRemoves, 0);
  });

  test('an exact old snapshot cannot remove a newly saved request from the same scope', () async {
    final platform = recoveryPlatform();
    const first = PrefsWorkshopPreferences(), second = PrefsWorkshopPreferences();
    final scope = recoveryScope(), old = recoveryPending();
    final replacement = recoveryPending(requestId: 'b' * 32);
    await first.savePendingSubmission(scope, old);
    final snapshot = await first.pendingRecovery(scope);
    await second.clearPendingSubmission(scope, old.requestId);
    await second.savePendingSubmission(scope, replacement);
    await expectLater(first.abandonPendingRecovery(snapshot), authError('workshop_confirmation_stale'));
    expect((await second.pendingSubmission(scope))!.requestId, replacement.requestId);
    expect(platform.pendingRemoves, 0);
  });

  test('even another scope changing invalidates the captured whole-key version while the target exists', () async {
    recoveryPlatform();
    const preferences = PrefsWorkshopPreferences();
    final scope = recoveryScope(), pending = recoveryPending();
    await preferences.savePendingSubmission(scope, pending);
    final snapshot = await preferences.pendingRecovery(scope);
    final other = recoveryScope(userId: 43);
    await PrefsWorkshopPreferences().savePendingSubmission(other, recoveryPending(scope: other));
    await expectLater(preferences.abandonPendingRecovery(snapshot), authError('workshop_confirmation_stale'));
    expect((await preferences.pendingSubmission(scope))!.requestId, pending.requestId);
  });

  test('ordinary pending writes and recovery share the same queue across preference instances', () async {
    final platform = recoveryPlatform();
    const one = PrefsWorkshopPreferences(), two = PrefsWorkshopPreferences();
    final scope = recoveryScope(), other = recoveryScope(userId: 43);
    await one.savePendingSubmission(scope, recoveryPending());
    final snapshot = await one.pendingRecovery(scope);
    final entered = Completer<void>(), release = Completer<void>();
    platform.beforePendingWrite = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final clearing = one.abandonPendingRecovery(snapshot);
    final cleared = authSettled(clearing);
    Future<void>? written;
    try {
      await authSignal(entered, clearing);
      final writing = two.savePendingSubmission(other, recoveryPending(scope: other));
      written = authSettled(writing);
      expect(platform.pendingWrites, 2); // Original save and held clear only.
      release.complete();
      await clearing;
      await writing;
      expect(await one.pendingSubmission(scope), isNull);
      expect(await two.pendingSubmission(other), isNotNull);
      expect(platform.pendingWrites, 3);
    } finally {
      if (!release.isCompleted) release.complete();
      await cleared;
      if (written != null) await written;
    }
  });

  test('a storage read failure produces no version and a later read can be retried', () async {
    final platform = recoveryPlatform({recoveryPendingKey: '{'})..failRead = true;
    const preferences = PrefsWorkshopPreferences();
    await expectLater(preferences.pendingRecovery(recoveryScope()), authError('workshop_preferences'));
    expect(platform.pendingWrites + platform.pendingRemoves, 0);
    platform.failRead = false;
    expect((await preferences.pendingRecovery(recoveryScope())).range, WorkshopPendingAbandonRange.allLocalAccounts);
  });

  for (final whole in [false, true]) {
    for (final persisted in [false, true]) {
      test('${whole ? 'whole-container' : 'current-entry'} clear failure persisted=$persisted keeps a safe retry', () async {
        final scope = recoveryScope();
        final raw = whole ? '{' : jsonEncode({scope: null});
        final platform = recoveryPlatform({recoveryPendingKey: raw});
        const preferences = PrefsWorkshopPreferences();
        final snapshot = await preferences.pendingRecovery(scope);
        platform.failPendingWrite = true;
        platform.persistBeforeFailure = persisted;
        await expectLater(preferences.abandonPendingRecovery(snapshot), authError('workshop_preferences'));
        expect(await platform.raw(recoveryPendingKey), persisted ? (whole ? null : '{}') : raw);
        platform.failPendingWrite = false;
        await PrefsWorkshopPreferences().abandonPendingRecovery(snapshot);
        expect(await preferences.pendingSubmission(scope), isNull);
        expect(platform.pendingWrites + platform.pendingRemoves, persisted ? 1 : 2);
      });
    }
  }

  test('a whole-container offer cannot remove a subsequently repaired container', () async {
    final platform = recoveryPlatform({recoveryPendingKey: '{'});
    const preferences = PrefsWorkshopPreferences();
    final scope = recoveryScope(), pending = recoveryPending();
    final snapshot = await preferences.pendingRecovery(scope);
    final replacement = jsonEncode({scope: pending.toJson()});
    await platform.setValue('String', 'flutter.$recoveryPendingKey', replacement);
    await expectLater(preferences.abandonPendingRecovery(snapshot), authError('workshop_confirmation_stale'));
    expect(await platform.raw(recoveryPendingKey), replacement);
    expect(platform.pendingRemoves, 0);
  });
}
