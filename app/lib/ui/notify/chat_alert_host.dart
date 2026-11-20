// The in-app half of notifications: a glass banner over every page when
// something happens in a conversation the person isn't looking at, plus the
// glue that tells the alert controller whether the app and the chat are on
// screen and routes notification taps.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../bots/bot_alerts.dart';
import '../common/discard_guard.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Put it once inside the home route (the home shell does). It keeps the
/// alert controller alive, feeds it the app lifecycle and whether the chat is
/// the current route, routes notification taps, and shows the banner in the
/// root overlay so it also appears over settings and other pages.
class ChatAlertHost extends ConsumerStatefulWidget {
  const ChatAlertHost({super.key, this.child, this.onReveal});

  /// Optional: the host itself draws nothing.
  final Widget? child;

  /// A tap is opening a conversation: the shell closes its drawer, animated
  /// for the banner (true), at once for a system notification (false).
  final ValueChanged<bool>? onReveal;

  @override
  ConsumerState<ChatAlertHost> createState() => _ChatAlertHostState();
}

class _ChatAlertHostState extends ConsumerState<ChatAlertHost> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<NotifyTap>? _taps;
  OverlayEntry? _entry;

  static bool _onScreen(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => ref.read(appForegroundProvider.notifier).set(_onScreen(state)),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(appForegroundProvider.notifier).set(_onScreen(WidgetsBinding.instance.lifecycleState));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuilt by the route whenever something is pushed over the chat or popped.
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(chatOnScreenProvider.notifier).set(current);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_taps?.cancel());
    _entry?.remove();
    _entry?.dispose();
    super.dispose();
  }

  /// Native side confirmed: route taps and give the banner its overlay slot.
  void _activate() {
    if (_taps != null) return;
    _taps = ref.read(notifyChannelProvider).taps.listen(_onTap);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      _entry = OverlayEntry(builder: (_) => AlertBannerLayer(onOpened: () => widget.onReveal?.call(true)));
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  Future<void> _onTap(NotifyTap tap) async {
    if (!mounted || !await DiscardGuard.confirmLeave(context) || !mounted) return;
    widget.onReveal?.call(false);
    // A Bot or group chat notification opens that chat.
    if (openDsBotTap(context, tap)) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    ref.read(chatAlertsProvider.notifier).open(tap.host, tap.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    // Without the native module (widget tests, desktop) nothing starts: no
    // host subscriptions, no tap stream, no banner.
    final native = ref.watch(notifySystemStatusProvider.select((s) => s.value?.native ?? false));
    if (native) {
      // Keeps the controller (and its host subscriptions) alive with the shell.
      ref.watch(chatAlertsProvider.select((_) => null));
      _activate();
    }
    return widget.child ?? const SizedBox.shrink();
  }
}

/// The banner slot in the root overlay: slides the current banner in from the
/// top, hides it after a few seconds or on an upward swipe, opens the
/// conversation on tap.
class AlertBannerLayer extends ConsumerStatefulWidget {
  const AlertBannerLayer({super.key, this.onOpened});

  /// After a tap has popped back to the chat and before it opens the conversation.
  final VoidCallback? onOpened;

  @override
  ConsumerState<AlertBannerLayer> createState() => _AlertBannerLayerState();
}

class _AlertBannerLayerState extends ConsumerState<AlertBannerLayer> {
  Timer? _timer;
  bool _accessibleNavigation = false;

  /// Requests stay longer: they wait on the person. With a screen reader the
  /// banner stays long enough to reach, and a request stays until handled.
  Duration? _shownFor(ChatAlert alert) => switch ((_accessibleNavigation, alert.kind.attention)) {
    (true, true) => null,
    (true, false) => const Duration(seconds: 12),
    (false, true) => const Duration(seconds: 6),
    (false, false) => const Duration(seconds: 4),
  };

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm(ChatAlert? alert) {
    _timer?.cancel();
    if (alert == null) return;
    if (_shownFor(alert) case final shown?) {
      _timer = Timer(shown, () => ref.read(chatAlertsProvider.notifier).dismissBanner(alert));
    }
  }

  Future<void> _open(ChatAlert alert) async {
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    HapticFeedback.selectionClick();
    final alerts = ref.read(chatAlertsProvider.notifier);
    alerts.dismissBanner(alert);
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    widget.onOpened?.call();
    alerts.open(alert.host, alert.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final accessible = MediaQuery.accessibleNavigationOf(context);
    if (accessible != _accessibleNavigation) {
      _accessibleNavigation = accessible;
      _arm(ref.read(chatAlertsProvider));
    }
    ref.listen(chatAlertsProvider, (_, next) => _arm(next));
    final alert = ref.watch(chatAlertsProvider);
    final activeHost = ref.watch(activeHostProvider);
    final hostName = alert == null || alert.host == activeHost
        ? null
        : hostLabel(alert.host.kind, ref.watch(hostNameProvider(alert.host)));
    final top = MediaQuery.viewPaddingOf(context).top + AppSpace.sm;
    final duration = AppMotion.of(context, AppMotion.emphasized);

    return Positioned(
      top: top,
      left: AppSpace.md,
      right: AppSpace.md,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: AnimatedSwitcher(
            duration: duration,
            reverseDuration: AppMotion.of(context, AppMotion.standard),
            switchInCurve: AppMotion.enter,
            switchOutCurve: AppMotion.exit,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, -0.6), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: alert == null
                ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                : _Swipeable(
                    key: ObjectKey(alert),
                    onDismiss: () => ref.read(chatAlertsProvider.notifier).dismissBanner(alert),
                    child: AlertBanner(
                      alert: alert,
                      hostName: hostName,
                      onTap: () => _open(alert),
                      onDismiss: () => ref.read(chatAlertsProvider.notifier).dismissBanner(alert),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Follows an upward drag and dismisses past a threshold or on a fling.
class _Swipeable extends StatefulWidget {
  const _Swipeable({super.key, required this.child, required this.onDismiss});

  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<_Swipeable> createState() => _SwipeableState();
}

class _SwipeableState extends State<_Swipeable> {
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) => setState(() => _dy = (_dy + d.delta.dy).clamp(-200.0, 12.0)),
      onVerticalDragEnd: (d) {
        if (_dy < -28 || (d.primaryVelocity ?? 0) < -400) {
          widget.onDismiss();
        } else {
          setState(() => _dy = 0);
        }
      },
      child: Transform.translate(offset: Offset(0, _dy), child: widget.child),
    );
  }
}

/// One alert as a floating glass card: status glyph, conversation title,
/// one or two lines of what happened.
class AlertBanner extends StatelessWidget {
  const AlertBanner({super.key, required this.alert, this.hostName, this.onTap, this.onDismiss});

  final ChatAlert alert;

  /// Set when the conversation is on a host other than the active one.
  final String? hostName;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final (icon, bg, fg) = switch (alert.kind) {
      AlertKind.done => (AppIcons.done, colors.successContainer, colors.onSuccessContainer),
      AlertKind.failed => (AppIcons.error, colors.dangerContainer, colors.onDangerContainer),
      AlertKind.stopped => (AppIcons.stop, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      AlertKind.approval => (AppIcons.approval, colors.warningContainer, colors.onWarningContainer),
      AlertKind.question => (AppIcons.question, colors.infoContainer, colors.onInfoContainer),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      button: onTap != null,
      onTap: onTap,
      onDismiss: onDismiss,
      label: '${alert.title}，${alert.text}${hostName == null ? '' : '，$hostName'}',
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: AppShape.radiusLg,
        onTap: onTap,
        child: Padding(
          // 12 all round: the icon disc sits as far from the top and left
          // edges as the text does from the right and bottom.
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(color: bg, shape: const CircleBorder()),
                child: SizedBox.square(dimension: 32, child: Icon(icon, size: 18, color: fg)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            alert.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.35),
                          ),
                        ),
                        if (hostName case final host?) ...[
                          const SizedBox(width: 6),
                          Text(
                            host,
                            maxLines: 1,
                            style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      alert.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
