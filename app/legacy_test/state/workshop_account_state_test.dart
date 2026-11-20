import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart';
import 'workshop_auth_test_support.dart' show AuthClient;

/// The real controller over an in-memory store, a scripted GitHub and a
/// pause between polls that the test releases (or skips).
class _World {
  _World({Map<String, String>? stored, String? clientId = 'Iv1.test', this.manualWait = false, MemorySecretStore? store})
    : store = store ?? MemorySecretStore(stored) {
    client.value = WorkshopCapabilities.fromJson(workshopCaps(clientId: clientId));
    container = ProviderContainer(overrides: [
      workshopAccountStoreProvider.overrideWithValue(this.store),
      workshopHttpFactoryProvider.overrideWithValue((_) => http),
      workshopClientProvider.overrideWith((ref) async => client),
      workshopAccountWaitProvider.overrideWithValue((interval) {
        waits.add(interval);
        if (!manualWait) return Future<void>.value();
        release = Completer<void>();
        return release!.future;
      }),
    ]);
  }
  final MemorySecretStore store;
  final client = AuthClient();
  final bool manualWait;
  final waits = <Duration>[];
  Completer<void>? release;
  late final ProviderContainer container;
  /// GitHub's answers, in order, keyed by path.
  final answers = <String, List<Object?>>{};
  late final http = FakeWorkshopHttp((method, url, headers, body) {
    final next = answers[url.path]!.removeAt(0);
    if (next is Exception) throw next;
    return workshopJsonResponse(next);
  });

  WorkshopAccountController get controller => container.read(workshopAccountProvider.notifier);
  WorkshopAccountState get state => container.read(workshopAccountProvider);
  Future<void> restored() async {
    state;
    await pumpEventQueue();
  }
}

Map<String, Object?> _code() => {'device_code': 'device_secret_0123', 'user_code': 'WDJB-MJHT',
  'verification_uri': 'https://github.com/login/device', 'expires_in': 900, 'interval': 5};

void main() {
  test('restores a stored account and treats an unreadable record as signed out', () async {
    final good = _World(stored: {workshopAccountKey: jsonEncode({'token': 'gho_saved', 'id': 7, 'login': 'octo'})});
    final bad = _World(stored: {workshopAccountKey: '{"token":"has space","id":7,"login":"octo"}'});
    final none = _World();
    addTearDown(good.container.dispose);
    addTearDown(bad.container.dispose);
    addTearDown(none.container.dispose);
    expect(good.state.phase, WorkshopAccountPhase.restoring);
    await Future.wait([good.restored(), bad.restored(), none.restored()]);
    expect((good.state.phase, good.state.id, good.state.login, good.state.credential!.token),
      (WorkshopAccountPhase.signedIn, 7, 'octo', 'gho_saved'));
    expect(good.state.credential.toString(), isNot(contains('gho_')));
    expect(bad.state.phase, WorkshopAccountPhase.signedOut);
    expect(none.state.phase, WorkshopAccountPhase.signedOut);
  });

  test('signs in: shows the code, slows down when asked, then stores the account', () async {
    final world = _World();
    addTearDown(world.container.dispose);
    await world.restored();
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [
      {'error': 'authorization_pending'}, {'error': 'slow_down'},
      {'access_token': 'gho_new_token', 'token_type': 'bearer', 'scope': ''},
    ];
    world.answers['/user'] = [{'id': 583231, 'login': 'octo-cat'}];
    final seen = <WorkshopAccountState>[];
    world.container.listen(workshopAccountProvider, (_, next) => seen.add(next));
    await world.controller.startSignIn();
    final waiting = seen.firstWhere((s) => s.phase == WorkshopAccountPhase.awaitingCode);
    expect((waiting.userCode, waiting.verificationUri.toString()), ('WDJB-MJHT', 'https://github.com/login/device'));
    expect(waiting.expiresAt, isNotNull);
    expect(world.waits, [const Duration(seconds: 5), const Duration(seconds: 5), const Duration(seconds: 10)]);
    expect((world.state.phase, world.state.id, world.state.login, world.state.error),
      (WorkshopAccountPhase.signedIn, 583231, 'octo-cat', null));
    expect(jsonDecode(world.store.values[workshopAccountKey]!), {'token': 'gho_new_token', 'id': 583231, 'login': 'octo-cat'});
  });

  for (final (answer, error) in [('expired_token', WorkshopAccountError.expired), ('access_denied', WorkshopAccountError.denied)]) {
    test('$answer ends signed out with ${error.name}', () async {
      final world = _World();
      addTearDown(world.container.dispose);
      await world.restored();
      world.answers['/login/device/code'] = [_code()];
      world.answers['/login/oauth/access_token'] = [{'error': answer}];
      await world.controller.startSignIn();
      expect((world.state.phase, world.state.error), (WorkshopAccountPhase.signedOut, error));
      expect(world.store.values, isEmpty);
    });
  }

  test('no client id means unconfigured, and GitHub is never asked', () async {
    final world = _World(clientId: null);
    addTearDown(world.container.dispose);
    await world.restored();
    await world.controller.startSignIn();
    expect(world.state.error, WorkshopAccountError.unconfigured);
    expect(world.http.requests, isEmpty);
  });

  test('a transport failure reads as network', () async {
    final world = _World();
    addTearDown(world.container.dispose);
    await world.restored();
    world.answers['/login/device/code'] = [const SocketException('offline')];
    await world.controller.startSignIn();
    expect((world.state.phase, world.state.error), (WorkshopAccountPhase.signedOut, WorkshopAccountError.network));
  });

  test('cancelling stops the poll; a later approval is never collected', () async {
    final world = _World(manualWait: true);
    addTearDown(world.container.dispose);
    await world.restored();
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [{'access_token': 'gho_late', 'token_type': 'bearer'}];
    final signingIn = world.controller.startSignIn();
    await pumpEventQueue();
    expect(world.state.phase, WorkshopAccountPhase.awaitingCode);
    world.controller.cancelSignIn();
    expect(world.state.phase, WorkshopAccountPhase.signedOut);
    world.release!.complete();
    await signingIn;
    expect(world.state.phase, WorkshopAccountPhase.signedOut);
    expect(world.http.requests.map((r) => r.url.path), ['/login/device/code']);
    expect(world.store.values, isEmpty);
  });

  test('cancelling while the account is being stored leaves nothing stored', () async {
    final store = _GatedStore();
    final world = _World(store: store);
    addTearDown(world.container.dispose);
    await world.restored();
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [{'access_token': 'gho_new_token', 'token_type': 'bearer', 'scope': ''}];
    world.answers['/user'] = [{'id': 583231, 'login': 'octo-cat'}];
    final done = world.controller.startSignIn();
    await store.writing.future;
    world.controller.cancelSignIn();
    store.gate.complete();
    await done;
    expect(world.state.phase, WorkshopAccountPhase.signedOut);
    expect(store.values, isEmpty);
  });

  test("a cancelled attempt's clean-up never deletes what the next attempt saved", () async {
    final store = _GatedStore();
    final world = _World(store: store);
    addTearDown(world.container.dispose);
    await world.restored();
    world.answers['/login/device/code'] = [_code(), _code()];
    world.answers['/login/oauth/access_token'] = [
      {'access_token': 'gho_first', 'token_type': 'bearer', 'scope': ''},
      {'access_token': 'gho_second', 'token_type': 'bearer', 'scope': ''},
    ];
    world.answers['/user'] = [{'id': 1, 'login': 'first'}, {'id': 2, 'login': 'second'}];
    final first = world.controller.startSignIn();
    await store.writing.future;
    world.controller.cancelSignIn();
    final second = world.controller.startSignIn();
    await pumpEventQueue();
    store.gate.complete();
    await Future.wait([first, second]);
    expect((world.state.phase, world.state.login), (WorkshopAccountPhase.signedIn, 'second'));
    expect(jsonDecode(store.values[workshopAccountKey]!), {'token': 'gho_second', 'id': 2, 'login': 'second'});
  });

  test('signing out and a refused token both forget the stored account', () async {
    for (final forget in [(WorkshopAccountController c) => c.signOut(), (WorkshopAccountController c) => c.markInvalid()]) {
      final world = _World(stored: {workshopAccountKey: jsonEncode({'token': 'gho_saved', 'id': 7, 'login': 'octo'})});
      addTearDown(world.container.dispose);
      await world.restored();
      expect(world.state.phase, WorkshopAccountPhase.signedIn);
      await forget(world.controller);
      expect((world.state.phase, world.state.credential), (WorkshopAccountPhase.signedOut, null));
      expect(world.store.values, isEmpty);
    }
  });
}

/// Holds the first write open until the test lets it finish.
class _GatedStore extends MemorySecretStore {
  final writing = Completer<void>(), gate = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    if (!writing.isCompleted) {
      writing.complete();
      await gate.future;
    }
    await super.write(key, value);
  }
}
