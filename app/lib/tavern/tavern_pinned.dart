// The state a card pins (docs/design/roleplay-ui.md §8: 顶栏那行小字放卡钉住的
// 状态；没钉的卡不显示): its pinPaths read out of the current message's state,
// for the chat's header line.

import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';

/// [state]'s pinned values on one line, `好感 8 · 地点 旅店`; null when the card
/// pins nothing, or nothing pinned has a value yet. What the card keeps from
/// the model (its hidden paths) is not put on show here.
String? tavernPinnedLine(TavernStateSnapshot state) {
  final values = state.valueExists
      ? state.values
      : state.initialValuesAvailable
      ? state.initialValues
      : null;
  final parts = <String>[
    for (final path in state.pinPaths)
      if (!state.hiddenPaths.any((hidden) => path == hidden || path.startsWith('$hidden/')))
        if (_at(values, path) case (true, final value)) '${_name(path)} ${_shown(value)}'.trim(),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The value at JSON Pointer [path], and whether there was one.
(bool, Object?) _at(Object? root, String path) {
  if (path.isEmpty) return (root != null, root);
  if (!path.startsWith('/')) return (false, null);
  var at = root;
  for (final raw in path.substring(1).split('/')) {
    final key = raw.replaceAll('~1', '/').replaceAll('~0', '~');
    final index = int.tryParse(key);
    if (at is Map<String, Object?> && at.containsKey(key)) {
      at = at[key];
    } else if (at is List<Object?> && index != null && index >= 0 && index < at.length) {
      at = at[index];
    } else {
      return (false, null);
    }
  }
  return (true, at);
}

/// The last step of [path], as the value's name.
String _name(String path) =>
    path.isEmpty ? '' : path.substring(path.lastIndexOf('/') + 1).replaceAll('~1', '/').replaceAll('~0', '~');

String _shown(Object? value) => switch (value) {
  final String text => text,
  null => '—',
  final List<Object?> list when list.every((item) => item is String) => list.join('、'),
  _ => jsonEncode(value),
};
