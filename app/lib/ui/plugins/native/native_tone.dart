// The colors behind a plugin's semantic tones (`good`, `warn`, `bad`, `info`).

import 'package:flutter/widgets.dart';

import '../../theme/theme.dart';

/// Null for `muted` and anything else: the place's own color.
Color? nativeToneColor(DshColors dsh, String? tone) => switch (tone) {
  'good' => dsh.success,
  'warn' => dsh.warning,
  'bad' => dsh.danger,
  'info' => dsh.info,
  _ => null,
};
