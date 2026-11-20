import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show FakeWorkshopHttp, workshopCaps;

final authWorker = Uri.parse('https://workshop.example');
final authAccount = Uri.parse('https://github.com');

Matcher authError(String code) => throwsA(isA<WorkshopException>().having((error) => error.code, 'code', code));

const authSignedOut = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut);

WorkshopAccountState authSignedIn({WorkshopAccountCredential? credential, int? userId = 42}) => WorkshopAccountState(
  phase: WorkshopAccountPhase.signedIn,
  credential: credential ?? const WorkshopAccountCredential('TEST_ONLY_KEY_A'),
  id: userId, login: userId == null ? null : 'test-user',
);

/// Holds a fixed account state instead of reading secure storage or GitHub.
class AuthAccountController extends WorkshopAccountController {
  AuthAccountController(this.initial);
  final WorkshopAccountState initial;
  int signInStarts = 0, invalidated = 0;
  @override
  WorkshopAccountState build() => initial;
  void emit(WorkshopAccountState value) => state = value;
  @override
  Future<void> startSignIn() async {
    signInStarts++;
    state = WorkshopAccountState(phase: WorkshopAccountPhase.awaitingCode, userCode: 'TEST-CODE',
      verificationUri: Uri.parse('https://github.com/login/device'), expiresAt: DateTime.utc(2030));
  }
  @override
  Future<void> markInvalid() async {
    invalidated++;
    state = authSignedOut;
  }
}

class AuthPreferences implements WorkshopPreferences {
  final accepted = <String>{};
  int writes = 0;
  Future<bool> Function(Uri worker, Uri account)? readDisclosure;
  Future<void> Function(Uri worker, Uri account)? writeDisclosure;
  String pair(Uri worker, Uri account) => jsonEncode([worker.toString(), account.toString()]);

  @override
  Future<bool> disclosureAccepted(Uri worker, Uri account) async =>
    readDisclosure == null ? accepted.contains(pair(worker, account)) : await readDisclosure!(worker, account);

  @override
  Future<void> acceptDisclosure(Uri worker, Uri account) async {
    writes++;
    if (writeDisclosure != null) await writeDisclosure!(worker, account);
    accepted.add(pair(worker, account));
  }

  // Auth has no submission journal responsibility. These calls would be a
  // test failure instead of silently persisting credentials or creating work.
  @override
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed) async => throw StateError('Auth touched request ids');
  @override
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId) async => throw StateError('Auth touched request ids');
  @override
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope) async => throw StateError('Auth touched pending submissions');
  @override
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission pending) async => throw StateError('Auth touched pending submissions');
  @override
  Future<void> clearPendingSubmission(String scope, String expectedRequestId) async => throw StateError('Auth touched pending submissions');
}

class AuthClient extends WorkshopClient {
  AuthClient({Uri? worker, Uri? account}) : super(origin: worker ?? authWorker,
    cacheFile: File('unused-auth-state-cache.json'),
    http: FakeWorkshopHttp((method, url, headers, body) => throw StateError('Auth test attempted HTTP'))) {
    value = WorkshopCapabilities.fromJson(workshopCaps(account: (account ?? authAccount).toString()));
  }
  late WorkshopCapabilities value;
  Future<WorkshopCapabilities> Function()? readCapabilities;
  int capabilityReads = 0;
  @override
  Future<WorkshopCapabilities> capabilities() async {
    capabilityReads++;
    return readCapabilities == null ? value : await readCapabilities!();
  }
}

final authClientChoiceProvider = NotifierProvider<AuthClientChoice, AuthClient>(AuthClientChoice.new);
class AuthClientChoice extends Notifier<AuthClient> {
  @override
  AuthClient build() => throw StateError('Auth client choice missing');
  void select(AuthClient value) => state = value;
}
class _InitialAuthClientChoice extends AuthClientChoice {
  _InitialAuthClientChoice(this.initial);
  final AuthClient initial;
  @override
  AuthClient build() => initial;
}

class AuthHarness {
  AuthHarness({AuthClient? client, AuthPreferences? preferences, WorkshopAccountState? initial,
    Future<WorkshopClient> Function(AuthClient)? loadClient})
    : client = client ?? AuthClient(), preferences = preferences ?? AuthPreferences(),
      account = AuthAccountController(initial ?? authSignedIn()) {
    container = ProviderContainer(overrides: [
      workshopAccountProvider.overrideWith(() => account),
      authClientChoiceProvider.overrideWith(() => _InitialAuthClientChoice(this.client)),
      workshopClientProvider.overrideWith((ref) async {
        final selected = ref.watch(authClientChoiceProvider);
        return loadClient == null ? selected : await loadClient(selected);
      }),
      workshopPreferencesProvider.overrideWithValue(this.preferences),
    ]);
  }
  final AuthClient client;
  final AuthPreferences preferences;
  final AuthAccountController account;
  late final ProviderContainer container;

  WorkshopAccessController get controller => container.read(workshopAccessProvider.notifier);
  WorkshopAccessState get state => container.read(workshopAccessProvider);
  void choose(AuthClient value) => container.read(authClientChoiceProvider.notifier).select(value);
  void dispose() => container.dispose();
}

Future<WorkshopAccessState> authReady(ProviderContainer container) {
  final done = Completer<WorkshopAccessState>();
  final subscription = container.listen(workshopAccessProvider, (previous, next) {
    if (!next.loading && !done.isCompleted) done.complete(next);
  }, fireImmediately: true, onError: (Object error, StackTrace stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  });
  return done.future.whenComplete(subscription.close);
}

Future<void> authSettled<T>(Future<T> pending) => pending.then<void>((_) {}, onError: (Object error, StackTrace stack) {});

Future<void> authSignal<T>(Completer<void> signal, Future<T> pending) => Future.any([
  signal.future,
  pending.then<void>((_) {
    if (!signal.isCompleted) fail('Auth operation ended before the expected signal');
  }),
]);
