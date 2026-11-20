// 「传文件到电脑」 atop the 「文件」 tab on a Remote computer: files picked on
// the phone go straight into the conversation's workspace on the computer
// (ds-harness-remote `workspace.upload.v1`), without sending a message.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart';
import '../../state/chat_error_text.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';

/// One row, shown only while the live connection is a Remote Host whose
/// plugin declared `workspace.upload.v1`. Files keep their original bytes
/// (the system file picker, not the gallery's downscaling); the Host puts
/// them at the workspace root and picks the final name on a clash.
class WorkspaceUploadRow extends ConsumerStatefulWidget {
  const WorkspaceUploadRow({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<WorkspaceUploadRow> createState() => _WorkspaceUploadRowState();
}

class _WorkspaceUploadRowState extends ConsumerState<WorkspaceUploadRow> {
  int _done = 0;
  int _total = 0;
  String? _current;

  bool get _busy => _total > 0;

  Future<void> _pickAndSend() async {
    final l10n = context.l10n;
    final PickedAttachments picked;
    try {
      picked = await ref.read(attachmentPickerProvider).pickFiles();
    } on PlatformException catch (e) {
      if (!mounted) return;
      showBriefNotice(
        context,
        e.code.contains('denied') || e.code.contains('permission')
            ? l10n.chatAttachmentPermission
            : chatErrorText(e, action: l10n.chatOpenAttachmentFailed),
      );
      return;
    } on Object catch (e) {
      if (mounted) showBriefNotice(context, chatErrorText(e, action: l10n.chatReadFailed));
      return;
    }
    if (!mounted) return;
    final files = picked.attachments;
    if (files.isEmpty) {
      if (picked.problem case final problem?) showBriefNotice(context, problem);
      return;
    }
    // Pinned to the connection the user picked on: a Host switch mid-way
    // ends the batch instead of sending the rest elsewhere.
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || !client.supportsWorkspaceUpload) {
      showBriefNotice(context, l10n.fileUploadFailed);
      return;
    }
    setState(() {
      _done = 0;
      _total = files.length;
    });
    final sent = <String>[];
    String? failure;
    bool stillHere() => mounted && identical(ref.read(activeConnectionProvider).value?.client, client);
    for (final file in files) {
      if (!stillHere()) break;
      setState(() => _current = file.name);
      try {
        final result = await client.uploadWorkspaceFile(widget.sessionId, file.bytes, name: file.name);
        sent.add(result.name);
      } on Object catch (e) {
        failure = chatErrorText(e, action: l10n.fileUploadFailed);
        break;
      }
      if (!mounted) return;
      setState(() => _done++);
    }
    if (!mounted) return;
    setState(() {
      _total = 0;
      _current = null;
    });
    // Another Host took over meanwhile: its folder and its page are not
    // where these files went.
    if (!stillHere()) return;
    if (sent.isNotEmpty) {
      unawaited(ref.read(workspaceDirProvider((widget.sessionId, '')).notifier).refresh());
    }
    final notice = [if (sent.isNotEmpty) l10n.fileUploadDone(sent.join('、')), ?failure, ?picked.problem].join('\n');
    if (notice.isNotEmpty) showBriefNotice(context, notice);
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
    if (client == null) return _busy ? _row(context) : const SizedBox.shrink();
    // The Host may gain or lose the capability on a reconnect in place, which
    // keeps the same client, and a dropped link has none: look again on every
    // connection state change.
    return StreamBuilder<Object?>(
      stream: client.mux.states,
      builder: (context, _) => client.supportsWorkspaceUpload || _busy ? _row(context) : const SizedBox.shrink(),
    );
  }

  Widget _row(BuildContext context) {
    final l10n = context.l10n;
    return ListPageCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      children: [
        ListPageRow(
          icon: AppIcons.uploadToHost,
          title: l10n.fileUploadToHost,
          subtitle: _busy
              ? l10n.fileUploadProgress((_done + 1).clamp(1, _total), _total, _current ?? '')
              : l10n.fileUploadToHostHint,
          trailing: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          chevron: !_busy,
          onTap: _busy ? null : () => unawaited(_pickAndSend()),
        ),
      ],
    );
  }
}
