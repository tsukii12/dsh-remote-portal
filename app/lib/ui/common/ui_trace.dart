import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Opt-in geometry/gesture diagnostics. Never enabled in release builds.
const uiTraceEnabled = !kReleaseMode && bool.fromEnvironment('DSH_UI_TRACE');

/// A separate A/B probe for the existing opaque fallback, never release UI.
const uiTraceNoBlur = !kReleaseMode && bool.fromEnvironment('DSH_UI_NO_BLUR');

/// Callers pass only dimensions, booleans and fixed event names, never text,
/// paths, session IDs or provider credentials.
void uiTrace(String scope, String event, Map<String, Object?> values) {
  if (!uiTraceEnabled) return;
  final finite = values.map((key, value) => MapEntry(key, value is num && !value.isFinite ? null : value));
  debugPrint(
    '[DSH_UI] ${jsonEncode({'time': DateTime.now().microsecondsSinceEpoch, 'scope': scope, 'event': event, ...finite})}',
  );
}

/// Observes notifications without consuming gestures or changing physics.
/// When disabled this adds no render object or notification listener.
class UiTrace extends StatelessWidget {
  const UiTrace({super.key, required this.scope, required this.child});

  final String scope;
  final Widget child;

  void _metrics(String event, ScrollMetrics metrics, int depth) {
    uiTrace(scope, event, {
      'depth': depth,
      'axis': metrics.axis.name,
      'pixels': metrics.pixels,
      'min': metrics.minScrollExtent,
      'max': metrics.maxScrollExtent,
      'viewport': metrics.viewportDimension,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!uiTraceEnabled) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        uiTrace(scope, 'layout', {
          'width': constraints.maxWidth,
          'height': constraints.maxHeight,
          'insetBottom': media.viewInsets.bottom,
          'paddingTop': media.padding.top,
          'paddingBottom': media.padding.bottom,
          'text16': media.textScaler.scale(16),
          'dpr': media.devicePixelRatio,
        });
        return Listener(
          onPointerDown: (_) => uiTrace(scope, 'pointer-down', const {}),
          onPointerUp: (_) => uiTrace(scope, 'pointer-up', const {}),
          onPointerCancel: (_) => uiTrace(scope, 'pointer-cancel', const {}),
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              _metrics('metrics', notification.metrics, notification.depth);
              return false;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _metrics(notification.runtimeType.toString(), notification.metrics, notification.depth);
                return false;
              },
              child: child,
            ),
          ),
        );
      },
    );
  }
}
