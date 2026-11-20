import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/media_settings.dart';
import '../../engine_settings/field_sheets.dart';

String? mediaUrlIssueText(L10n l10n, MediaUrlIssue? issue) => switch (issue) {
  MediaUrlIssue.invalid => l10n.mediaConfigUrlInvalid,
  MediaUrlIssue.endpoint => l10n.mediaConfigUrlEndpoint,
  MediaUrlIssue.rootRequired => l10n.mediaConfigUrlRoot,
  null => null,
};

Future<bool> confirmMediaTarget(BuildContext context, String before, String after) async {
  if (!mediaTargetOriginChanged(before, after)) return true;
  final l10n = context.l10n;
  // Origins only: never echo URL credentials, query strings or fragments.
  String target(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.hasAuthority && (uri.scheme == 'https' || uri.scheme == 'http')
        ? uri.origin
        : l10n.mediaConfigKeyUnknown;
  }

  return await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.mediaConfigTargetTitle),
          content: Text(l10n.mediaConfigTargetBody(target(before), target(after))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.mediaConfigTargetConfirm)),
          ],
        ),
      ) ==
      true;
}

/// Only edits a root. The captured editor in onSave preserves host affinity.
class MediaUrlSheet extends StatefulWidget {
  const MediaUrlSheet({super.key, required this.service, required this.catalog, required this.onSave, this.defaultUrl});
  final MediaServiceConfig service;
  final Object? catalog;
  final String? defaultUrl;
  final Future<bool> Function(String) onSave;

  @override
  State<MediaUrlSheet> createState() => _MediaUrlSheetState();
}

class _MediaUrlSheetState extends State<MediaUrlSheet> {
  late final _controller = TextEditingController(text: widget.service.baseUrl);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final value = _controller.text.trim();
    if (mediaBaseUrlIssue(value, widget.service.profile) != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.service.keyRef.isNotEmpty && !await confirmMediaTarget(context, widget.service.baseUrl, value)) return;
      if (!mounted) return;
      final saved = await widget.onSave(value);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = context.l10n.commonSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final issue = mediaBaseUrlIssue(_controller.text, widget.service.profile);
    final preview = mediaRequestPreview(_controller.text, widget.service.profile, widget.catalog);
    return FieldSheetFrame(
      title: l10n.mediaSettingsBaseUrl,
      actions: SheetActions(
        primary: FilledButton(onPressed: _busy || issue != null ? null : _save, child: Text(l10n.commonDone)),
        secondary: widget.defaultUrl == null
            ? null
            : OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _controller.text = widget.defaultUrl!;
                        _error = null;
                      }),
                child: Text(l10n.engineFieldRestoreDefault),
              ),
      ),
      children: [
        Text(l10n.mediaConfigUrlHint),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('media-url-input'),
          controller: _controller,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(errorText: mediaUrlIssueText(l10n, issue), errorMaxLines: 4),
        ),
        const SizedBox(height: 12),
        Text(l10n.mediaConfigPreview),
        SelectableText(preview == null ? l10n.mediaConfigPreviewUnavailable : 'POST $preview'),
        SheetHelper(helper: l10n.mediaConfigPreviewNote, error: _error),
      ],
    );
  }
}
