import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// The schedule Host sends a warning followed by the complete reviewed task.
/// Keep every field, including unfamiliar ones, and keep the choices outside
/// this scroll area. Rendering never changes the question or its answer.
class ScheduleQuestionBody extends StatelessWidget {
  const ScheduleQuestionBody({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final split = text.lastIndexOf('\n\n');
    Object? details;
    if (split >= 0) {
      try {
        details = jsonDecode(text.substring(split + 2));
      } on FormatException {
        // Older or changed Host formats remain available in their entirety.
      }
    }
    final body = details is Map<String, dynamic>
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Text(_visible(text.substring(0, split))), const SizedBox(height: 12), _value(context, details)],
          )
        : Text(_visible(text));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: Scrollbar(
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.only(right: 8),
          child: DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _value(BuildContext context, Object? value) {
    final entries = switch (value) {
      Map<String, dynamic>() => value.entries.toList(),
      List() => [for (var i = 0; i < value.length; i++) MapEntry('[$i]', value[i])],
      _ => null,
    };
    if (entries == null || entries.isEmpty) {
      return Text(value is String ? _visible(value) : jsonEncode(value));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries) ...[
          Text(
            _label(context, entry.key),
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          Padding(padding: const EdgeInsets.only(left: 12, bottom: 8), child: _value(context, entry.value)),
        ],
      ],
    );
  }

  String _label(BuildContext context, String field) {
    final l10n = context.l10n;
    return switch (field) {
      'title' => l10n.commonName,
      'prompt' => l10n.featuresScheduleInstruction,
      'time' => l10n.featuresTime,
      'timeZone' => l10n.featuresTimeZone,
      'scheduledAt' => l10n.featuresScheduleNextRun,
      'status' => l10n.commonStatus,
      _ => _visible(field).replaceAll('\n', r'\n'),
    };
  }

  // JSON decoding restores the Host's escaped formatting controls. Keep those
  // controls visible again, in both keys and values; only real line feeds are
  // displayed as line breaks. Never render task instructions as Markdown.
  static String _visible(String value) => value.replaceAllMapped(
    RegExp(r'[\u0000-\u0009\u000b-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]'),
    (match) => r'\u' + match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0'),
  );
}
