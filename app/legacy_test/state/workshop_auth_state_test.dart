import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show workshopCaps;
import 'workshop_auth_test_support.dart';

void main() {
  test('cold disclosure storage cannot authorize before its result arrives', () async {
    final preferences = AuthPreferences();
    final entered = Completer<void>(), release = Completer<bool>();
    preferences.readDisclosure = (worker, account) { entered.complete(); return release.future; };
    final harness = AuthHarness(preferences: preferences);
    final ready = authReady(harness.container);
    final readySettled = authSettled(ready);
    final authorization = harness.controller.authorize();
    final authorizationSettled = authSettled(authorization);
    try {
      await authSignal(entered, ready);
      expect(harness.state.loading, isTrue);
      expect(harness.state.canAuthenticate, isFalse);
      expect(harness.state.disclosureAccepted, isFalse);
      release.complete(false);
      await ready;
      await expectLater(authorization, authError('workshop_consent_required'));
      expect(harness.state.disclosure!.worker, authWorker);
      expect(harness.state.disclosure!.account, authAccount);
      expect(preferences.writes, 0);
    } finally {
      if (!release.isCompleted) release.complete(false);
      await authorizationSettled;
      await readySettled;
      harness.dispose();
    }
  });

  for (final phase in [WorkshopAccountPhase.restoring, WorkshopAccountPhase.signedOut]) {
    test('account ${phase.name} never provides a credential disclosure action', () async {
      final harness = AuthHarness(initial: WorkshopAccountState(phase: phase));
      try {
        await authReady(harness.container);
        expect(harness.state.signedIn, isFalse);
        expect(harness.state.accountRestoring, phase == WorkshopAccountPhase.restoring);
        expect(harness.state.disclosure, isNull);
        expect(harness.state.canSubmit('pet'), isFalse);
        await expectLater(harness.controller.authorize(), authError('workshop_account_auth_required'));
      } finally { harness.dispose(); }
    });
  }

  test('explicit source confirmation persists and authorization has only a public request scope', () async {
    final harness = AuthHarness();
    try {
      await authReady(harness.container);
      final offered = harness.state.disclosure!;
      expect(harness.state.canAuthenticate, isFalse);
      await harness.controller.confirmDisclosure(offered);
      expect(harness.state.disclosureAccepted, isTrue);
      expect(harness.state.disclosureSaved, isTrue);
      expect(harness.state.preferenceError, isNull);
      expect(harness.state.canSubmit('pet'), isTrue);
      final authorization = await harness.controller.authorize();
      expect(authorization.client, same(harness.client));
      expect(authorization.credential.worker, authWorker);
      expect(authorization.credential.account, authAccount);
      expect(authorization.accountId, 42);
      expect(jsonDecode(authorization.requestScope!), [authWorker.toString(), authAccount.toString(), 42]);
      expect(authorization.requestScope, isNot(contains('TEST_ONLY_KEY_A')));
      expect(authorization.credential.toString(), 'WorkshopCredential(redacted)');
      expect(harness.preferences.accepted, {harness.preferences.pair(authWorker, authAccount)});
    } finally { harness.dispose(); }
  });

  test('failed durable confirmation remains explicit in-memory consent and a retry can persist it', () async {
    final preferences = AuthPreferences()
      ..writeDisclosure = (worker, account) async => throw const WorkshopException('workshop_preferences');
    final harness = AuthHarness(preferences: preferences);
    AuthHarness? restarted;
    try {
      await authReady(harness.container);
      await harness.controller.confirmDisclosure(harness.state.disclosure!);
      expect(harness.state.disclosureAccepted, isTrue);
      expect(harness.state.disclosureSaved, isFalse);
      expect(harness.state.preferenceError!.code, 'workshop_preferences');
      expect((await harness.controller.authorize()).credential.worker, authWorker);
      restarted = AuthHarness(preferences: preferences);
      await authReady(restarted.container);
      expect(restarted.state.disclosureAccepted, isFalse);
      preferences.writeDisclosure = null;
      await harness.controller.confirmDisclosure(harness.state.disclosure!);
      expect(harness.state.disclosureSaved, isTrue);
      expect(harness.state.preferenceError, isNull);
      await restarted.controller.refresh();
      expect(restarted.state.disclosureAccepted, isTrue);
      expect(restarted.state.disclosureSaved, isTrue);
      expect(preferences.writes, 2);
    } finally {
      restarted?.dispose();
      harness.dispose();
    }
  });

  test('account origin mismatch blocks credentials and a disclosure offer', () async {
    final harness = AuthHarness(client: AuthClient(account: Uri.parse('https://another-account.example')));
    try {
      await authReady(harness.container);
      expect(harness.state.error!.code, 'workshop_account_origin');
      expect(harness.state.disclosure, isNull);
      expect(harness.state.canAuthenticate, isFalse);
      await expectLater(harness.controller.authorize(), authError('workshop_account_origin'));
      expect(harness.preferences.writes, 0);
    } finally { harness.dispose(); }
  });

  test('capability switches limit submission without inventing a signed-out state', () async {
    final preferences = AuthPreferences()..accepted.add(jsonEncode([authWorker.toString(), authAccount.toString()]));
    final client = AuthClient()..value = WorkshopCapabilities.fromJson(workshopCaps(uploads: false, companion: false));
    final harness = AuthHarness(client: client, preferences: preferences);
    try {
      await authReady(harness.container);
      expect(harness.state.canAuthenticate, isTrue);
      expect(harness.state.signedIn, isTrue);
      expect(harness.state.canSubmit('pet'), isFalse);
      expect(harness.state.canSubmit('companion'), isFalse);
      client.value = WorkshopCapabilities.fromJson(workshopCaps(companion: false));
      await harness.controller.refresh();
      expect(harness.state.canSubmit('pet'), isTrue);
      expect(harness.state.canSubmit('companion'), isFalse);
      expect(harness.state.canSubmit('future-kind'), isFalse);
    } finally { harness.dispose(); }
  });

  test('first profile arrival retains the credential session and supplies the public scope', () async {
    const credentials = WorkshopAccountCredential('TEST_ONLY_KEY_A');
    final preferences = AuthPreferences()..accepted.add(jsonEncode([authWorker.toString(), authAccount.toString()]));
    final harness = AuthHarness(preferences: preferences, initial: authSignedIn(credential: credentials, userId: null));
    try {
      await authReady(harness.container);
      final session = harness.state.session;
      expect(harness.state.canAuthenticate, isTrue);
      expect(harness.state.canSubmit('pet'), isFalse);
      expect((await harness.controller.authorize()).requestScope, isNull);
      harness.account.emit(authSignedIn(credential: credentials));
      await authReady(harness.container);
      expect(harness.state.session, same(session));
      expect(harness.state.canSubmit('pet'), isTrue);
      expect(jsonDecode((await harness.controller.authorize()).requestScope!),
        [authWorker.toString(), authAccount.toString(), 42]);
    } finally { harness.dispose(); }
  });

  test('a changed known account id invalidates its old disclosure object', () async {
    const credentials = WorkshopAccountCredential('TEST_ONLY_KEY_A');
    final harness = AuthHarness(initial: authSignedIn(credential: credentials));
    try {
      await authReady(harness.container);
      final session = harness.state.session, oldOffer = harness.state.disclosure!;
      harness.account.emit(authSignedIn(credential: credentials, userId: null));
      await authReady(harness.container);
      expect(harness.state.session, same(session));
      expect(harness.state.accountId, isNull);
      expect(harness.state.canSubmit('pet'), isFalse);
      harness.account.emit(authSignedIn(credential: credentials, userId: 43));
      await authReady(harness.container);
      expect(harness.state.session, isNot(same(session)));
      expect(harness.state.accountId, 43);
      await harness.controller.confirmDisclosure(oldOffer);
      expect(harness.state.error!.code, 'workshop_confirmation_stale');
      expect(harness.preferences.writes, 0);
      expect(harness.state.disclosureAccepted, isFalse);
    } finally { harness.dispose(); }
  });

  test('key rotation cancels an old authorization even before the new state is read', () async {
    final harness = AuthHarness();
    final entered = Completer<void>(), release = Completer<bool>();
    Future<void>? refreshing;
    Future<WorkshopAuthorization>? authorization;
    try {
      await authReady(harness.container);
      final oldOffer = harness.state.disclosure!, oldSession = harness.state.session;
      var reads = 0;
      harness.preferences.readDisclosure = (worker, account) async {
        if (reads++ == 0) { entered.complete(); return release.future; }
        return false;
      };
      refreshing = harness.controller.refresh();
      final refreshingSettled = authSettled(refreshing);
      await authSignal(entered, refreshing);
      authorization = harness.controller.authorize();
      final authorizationSettled = authSettled(authorization);
      harness.account.emit(authSignedIn(credential:
        const WorkshopAccountCredential('TEST_ONLY_KEY_B')));
      release.complete(false);
      await expectLater(authorization, authError('workshop_cancelled'));
      await refreshing;
      await authReady(harness.container);
      expect(harness.state.session, isNot(same(oldSession)));
      await harness.controller.confirmDisclosure(oldOffer);
      expect(harness.state.error!.code, 'workshop_confirmation_stale');
      expect(harness.preferences.writes, 0);
      await authorizationSettled;
      await refreshingSettled;
    } finally {
      if (!release.isCompleted) release.complete(false);
      if (authorization != null) await authSettled(authorization);
      if (refreshing != null) await authSettled(refreshing);
      harness.dispose();
    }
  });

  test('a Worker switch cannot consume a disclosure for the previous Worker', () async {
    final harness = AuthHarness();
    final entered = Completer<void>(), release = Completer<WorkshopCapabilities>();
    final next = AuthClient(worker: Uri.parse('https://new-workshop.example'));
    next.readCapabilities = () { entered.complete(); return release.future; };
    Future<WorkshopAccessState>? ready;
    try {
      await authReady(harness.container);
      final offered = harness.state.disclosure!;
      harness.choose(next);
      ready = authReady(harness.container);
      final settled = authSettled(ready);
      await authSignal(entered, ready);
      await harness.controller.confirmDisclosure(offered);
      expect(harness.state.error!.code, 'workshop_confirmation_stale');
      expect(harness.preferences.writes, 0);
      release.complete(next.value);
      await ready;
      expect(harness.state.worker, next.origin);
      expect(harness.state.disclosureAccepted, isFalse);
      expect(harness.state.disclosure!.worker, next.origin);
      await settled;
    } finally {
      if (!release.isCompleted) release.complete(next.value);
      if (ready != null) await authSettled(ready);
      harness.dispose();
    }
  });

  test('waiting for a GitHub code keeps the signed-out session; availability follows capabilities', () async {
    final client = AuthClient()..value = WorkshopCapabilities.fromJson(workshopCaps(clientId: null));
    final harness = AuthHarness(client: client, initial: authSignedOut);
    try {
      await authReady(harness.container);
      expect(harness.state.signInAvailable, isFalse);
      final session = harness.state.session;
      await harness.account.startSignIn();
      expect(harness.state.session, same(session));
      expect(harness.state.signedIn, isFalse);
      client.value = WorkshopCapabilities.fromJson(workshopCaps());
      await harness.controller.refresh();
      expect(harness.state.signInAvailable, isTrue);
      expect(harness.state.session, same(session));
    } finally { harness.dispose(); }
  });

  test('explicit refresh retries a failed client dependency with the replacement context', () async {
    var attempts = 0;
    final harness = AuthHarness(loadClient: (client) async {
      attempts++;
      if (attempts == 1) throw const WorkshopException('workshop_storage');
      return client;
    });
    try {
      await authReady(harness.container);
      expect(harness.state.error!.code, 'workshop_storage');
      expect(attempts, 1);
      expect(harness.client.capabilityReads, 0);
      await harness.controller.refresh();
      expect(attempts, 2);
      expect(harness.state.error, isNull);
      expect(harness.state.disclosure!.worker, authWorker);
      expect(harness.state.loading, isFalse);
    } finally { harness.dispose(); }
  });

  test('a newer capability refresh invalidates an authorization waiting on the older load', () async {
    final preferences = AuthPreferences()..accepted.add(jsonEncode([authWorker.toString(), authAccount.toString()]));
    final harness = AuthHarness(preferences: preferences);
    final entered = Completer<void>(), release = Completer<WorkshopCapabilities>();
    Future<void>? oldRefresh;
    Future<WorkshopAuthorization>? authorization;
    try {
      await authReady(harness.container);
      var reads = 0;
      harness.client.readCapabilities = () async {
        if (reads++ == 0) { entered.complete(); return release.future; }
        return WorkshopCapabilities.fromJson(workshopCaps(companion: false));
      };
      oldRefresh = harness.controller.refresh();
      final refreshSettled = authSettled(oldRefresh);
      await authSignal(entered, oldRefresh);
      authorization = harness.controller.authorize();
      final authorizationSettled = authSettled(authorization);
      await harness.controller.refresh();
      expect(harness.state.companionEnabled, isFalse);
      release.complete(WorkshopCapabilities.fromJson(workshopCaps()));
      await oldRefresh;
      await expectLater(authorization, authError('workshop_cancelled'));
      expect(harness.state.companionEnabled, isFalse);
      await authorizationSettled;
      await refreshSettled;
    } finally {
      if (!release.isCompleted) release.complete(WorkshopCapabilities.fromJson(workshopCaps()));
      if (authorization != null) await authSettled(authorization);
      if (oldRefresh != null) await authSettled(oldRefresh);
      harness.dispose();
    }
  });
}
