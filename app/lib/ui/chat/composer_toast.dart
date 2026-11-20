// A confirmation for something just put into the composer, floating clear of
// it instead of covering it.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/brief_notice.dart';

/// Room between the toast and the top of the composer (keyboard up).
const composerToastGap = 8.0;

/// How long a toast with an action stays: the SnackBar default, long enough
/// to reach the action. It still goes on its own (`persist: false`).
const composerToastActionDuration = Duration(seconds: 4);

/// Shows a toast above the composer, with an optional action; see
/// [showComposerToast].
typedef ComposerToast = void Function(String message, {String? actionLabel, VoidCallback? onAction});

/// Shows [message] briefly ([briefNoticeDuration]) just above the composer,
/// so the text that was just inserted stays in view.
///
/// [composerHeight] is the composer slot measured from the bottom of the chat
/// page; under its content sits at least [safeMinimum], more over a gesture
/// bar. A floating SnackBar stands on the larger of the gesture bar and the
/// keyboard. The composer was just focused, so the lift is measured for the
/// keyboard that is coming up (the gesture-bar inset is gone then): [gap]
/// with it up, a little more for the moment before.
///
/// With an action ([actionLabel] / [onAction], 「返回原对话」) it stays
/// [composerToastActionDuration], then goes like any other.
void showComposerToast(
  BuildContext context,
  String message, {
  required double composerHeight,
  double safeMinimum = 8,
  double gap = composerToastGap,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  final content = composerHeight - math.max(bottom, safeMinimum);
  final margin = EdgeInsets.fromLTRB(16, 0, 16, math.max(0.0, content) + safeMinimum + gap);
  ScaffoldMessenger.maybeOf(context)
    ?..removeCurrentSnackBar()
    ..showSnackBar(
      actionLabel == null
          ? briefNoticeBar(message, margin: margin)
          : SnackBar(
              content: Text(message),
              duration: composerToastActionDuration,
              persist: false,
              action: SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
              margin: margin,
            ),
    );
}
