import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/account_state.dart';
import '../../state/onboarding_state.dart';
import '../account/account_widgets.dart';
import '../common/progress_halo.dart';
import '../providers/provider_form_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'api_key_page.dart';
import 'onboarding_scaffold.dart';
import 'setup_progress.dart';

/// First-run "connect DeepSeek" step: DeepSeek account sign-in first (no API
/// key needed), the API key as the alternative, another provider (own Base URL
/// and key), or skip for now.
///
/// The engine is started as soon as this page shows: the browser callback is
/// served by the local engine, and both paths need it anyway.
///
/// While the runtime still unpacks (first run, set up beside it) the account
/// way has to wait for it: 「用 DeepSeek 账号登录」 then shows the unpack
/// with 「就绪后自动打开 DeepSeek 登录」 and goes on by itself once it is
/// done. The API key needs no engine and is saved at once.
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key, required this.onDone});

  /// Called after a successful sign-in, a saved key, a saved custom provider,
  /// or "稍后设置".
  final VoidCallback onDone;

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  late final AppLifecycleListener _lifecycle;
  bool _keyEntry = false;
  bool _succeeded = false;

  /// Asked to sign in while the runtime unpacks: waiting for it.
  bool _awaitingRuntime = false;

  /// The runtime came while the app was away: the sign-in opens once the
  /// person is back, not behind their back (Android would not let a browser
  /// open from the background anyway).
  bool _signInOnReturn = false;

  /// Depth of the page shown last (choice 0, key entry / signing in 1): going
  /// deeper slides forward, coming back slides back.
  int _depth = 0;
  bool _forward = true;
  Timer? _doneTimer;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A runtime still unpacking (or whose unpack failed) has no engine to start.
      final runtime = _runtime;
      if (runtime == SetupRuntime.unpacking || runtime == SetupRuntime.failed) return;
      unawaited(ref.read(accountEngineStarterProvider)().catchError((_) {}));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _doneTimer?.cancel();
    super.dispose();
  }

  /// Set up beside an unpack (first run on this phone).
  bool get _besideUnpack => OnboardingProgress.maybeOf(context)?.runtime ?? false;

  /// Where the runtime stands, when the app has heard from it. Not asked for
  /// otherwise: reading it would start listening to the native side, which
  /// the page alone has no reason to do (the account controller holds back
  /// the same way).
  SetupRuntime? get _runtime => ref.exists(localRuntimeProvider) ? ref.read(setupRuntimeProvider) : null;

  Future<void> _signIn() async {
    final runtime = _runtime;
    if (runtime == SetupRuntime.unpacking || (_besideUnpack && runtime == SetupRuntime.absent)) {
      ref.read(accountProvider.notifier).dismissFailure();
      setState(() => _awaitingRuntime = true);
      return;
    }
    if (_besideUnpack && runtime == SetupRuntime.failed) {
      _showUnpackFailure();
      return;
    }
    await ref.read(accountProvider.notifier).signIn(brightness: Theme.of(context).brightness);
  }

  void _showUnpackFailure() =>
      unawaited(showSetupStatusSheet(context, onRemote: OnboardingProgress.maybeOf(context)?.onRemote));

  void _onResume() {
    ref.read(accountProvider.notifier).noteAppResumed();
    if (_signInOnReturn) _continueSignIn();
  }

  /// Off screen: hidden, paused or gone (inactive is still on screen, under a
  /// notification shade or a system dialog).
  static bool get _away => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => true,
    _ => false,
  };

  /// The runtime the queued sign-in waits for came, or failed.
  void _onRuntime(SetupRuntime? _, SetupRuntime next) {
    if (!_awaitingRuntime) return;
    if (next == SetupRuntime.ready) {
      if (_away) {
        _signInOnReturn = true;
      } else {
        _continueSignIn();
      }
    } else if (next == SetupRuntime.failed) {
      _stopAwaiting();
      _showUnpackFailure();
    }
  }

  void _continueSignIn() {
    if (!_awaitingRuntime) return;
    _stopAwaiting();
    unawaited(_signIn());
  }

  /// Back to the ways in (取消, back, or the runtime is here or failed).
  void _stopAwaiting() => setState(() {
    _awaitingRuntime = false;
    _signInOnReturn = false;
  });

  void _onSignedIn() {
    if (_succeeded) return;
    setState(() => _succeeded = true);
    // Signed in counts as "connected": don't bring this step back on the next launch.
    unawaited(ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true));
    _doneTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) widget.onDone();
    });
  }

  Future<void> _skip() async {
    await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    widget.onDone();
  }

  /// The add-provider form over this step; the engine is already starting.
  Future<void> _otherProvider() async {
    ref.read(accountProvider.notifier).dismissFailure();
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ProviderFormPage()));
    if (id == null || !mounted) return;
    await ref.read(onboardingPrefsProvider.notifier).setKeySkipped(true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(accountProvider.select((s) => s.signedIn), (prev, signedIn) {
      if (signedIn && prev == false) _onSignedIn();
    });
    if (_awaitingRuntime) ref.listen(setupRuntimeProvider, _onRuntime);
    final state = ref.watch(accountProvider);
    final Widget page;
    if (_awaitingRuntime) {
      page = _AwaitRuntime(key: const ValueKey('await'), onCancel: _stopAwaiting);
    } else if (_keyEntry) {
      page = ApiKeyPage(
        key: const ValueKey('key'),
        onDone: widget.onDone,
        onBack: () => setState(() => _keyEntry = false),
      );
    } else if (_succeeded || state.signingIn) {
      page = _SigningIn(key: const ValueKey('signing'), state: state, succeeded: _succeeded);
    } else {
      page = _Choose(
        key: const ValueKey('choose'),
        state: state,
        onSignIn: _signIn,
        onApiKey: () {
          ref.read(accountProvider.notifier).dismissFailure();
          setState(() => _keyEntry = true);
        },
        onOther: _otherProvider,
        onSkip: _skip,
      );
    }
    final depth = page is _Choose ? 0 : 1;
    if (depth != _depth) {
      _forward = depth > _depth;
      _depth = depth;
    }
    return PopScope<void>(
      canPop: page is _Choose,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _succeeded) return;
        if (_awaitingRuntime) {
          _stopAwaiting();
        } else if (_keyEntry) {
          setState(() => _keyEntry = false);
        } else if (state.signingIn) {
          unawaited(ref.read(accountProvider.notifier).cancel());
        }
      },
      child: OnboardingSwitcher(forward: _forward, child: page),
    );
  }
}

class _Choose extends StatelessWidget {
  const _Choose({
    super.key,
    required this.state,
    required this.onSignIn,
    required this.onApiKey,
    required this.onOther,
    required this.onSkip,
  });

  final AccountState state;
  final VoidCallback onSignIn;
  final VoidCallback onApiKey;
  final VoidCallback onOther;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final unsupported = state.phase == AccountPhase.unsupported;
    return OnboardingScaffold(
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.account,
          title: l10n.shellConnectDeepSeek,
          message: l10n.shellConnectDeepSeekMessage,
        ),
        const SizedBox(height: 28),
        const AccountFacts(),
        if (state.failure case final failure?) ...[const SizedBox(height: 16), SignInFailureCard(failure: failure)],
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        if (unsupported)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.shellAccountSignInUnsupported,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
          )
        else ...[
          FilledButton(onPressed: onSignIn, child: Text(l10n.shellSignInDeepSeek)),
          const SizedBox(height: 10),
        ],
        OutlinedButton(onPressed: onApiKey, child: Text(l10n.shellUseApiKey)),
        const SizedBox(height: 6),
        // Two equal halves: the quieter ways on.
        Row(
          children: [
            for (final (label, onTap) in [(l10n.shellOtherProviders, onOther), (l10n.shellSetUpLater, onSkip)])
              Expanded(
                child: TextButton(
                  onPressed: onTap,
                  style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                  child: Text(label),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SigningIn extends StatelessWidget {
  const _SigningIn({super.key, required this.state, required this.succeeded});

  final AccountState state;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      children: [
        const Spacer(flex: 3),
        SignInStatus(state: state, succeeded: succeeded, haloSize: 148),
        const Spacer(flex: 3),
        const SizedBox(height: 24),
        // Keep the slot when done so the halo does not jump.
        Opacity(
          opacity: succeeded ? 0 : 1,
          child: IgnorePointer(
            ignoring: succeeded,
            child: SignInActions(state: state),
          ),
        ),
      ],
    );
  }
}

/// Signing in waits for the runtime: its unpack in the halo, and the promise
/// that the sign-in opens by itself. The page is the progress, so no capsule.
class _AwaitRuntime extends ConsumerWidget {
  const _AwaitRuntime({super.key, required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final progress = ref.watch(localRuntimeProvider.select((s) => s.progress));
    final meta = installMetaLine(l10n, progress, ref.watch(installEtaProvider));
    return OnboardingScaffold(
      showRuntime: false,
      children: [
        const Spacer(flex: 3),
        Center(
          child: ProgressHalo(
            value: progress?.fraction,
            size: 148,
            strokeWidth: 4,
            child: progress == null ? null : SetupPercent(value: progress.fraction, size: 34),
          ),
        ),
        const SizedBox(height: 28),
        Text(l10n.shellRuntimePreparing, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          l10n.setupAwaitSignIn,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        // The slot stays when there is nothing to say yet: no jump when there is.
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: MediaQuery.textScalerOf(context).scale(12) * 1.5),
          child: meta == null
              ? null
              : Text(
                  meta,
                  textAlign: TextAlign.center,
                  style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                ),
        ),
        const Spacer(flex: 3),
        const SizedBox(height: 24),
        OutlinedButton(onPressed: onCancel, child: Text(l10n.commonCancel)),
      ],
    );
  }
}
