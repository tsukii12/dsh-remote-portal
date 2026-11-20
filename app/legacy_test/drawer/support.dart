// Shared setup for the drawer tests: a host that archives, fixed
// pending / unread state, the stored folders and the emoji font.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';

import '../workspace/support.dart';

/// [FakeWorkspaceHost] that also archives and unarchives.
class DrawerHost extends FakeWorkspaceHost {
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspace/archiveSession' && endpoint != 'workspace/unarchiveSession') {
      return super.call(endpoint, args, timeout: timeout);
    }
    calls.add((endpoint, args));
    final request = args['request']! as Map;
    final id = request['sessionId']! as String;
    if (endpoint == 'workspace/archiveSession') {
      archived = [...archived, id];
      pinned = pinned.where((value) => value != id).toList();
      push({'type': 'pinned', 'pinnedSessionIds': pinned});
    } else {
      archived = archived.where((value) => value != id).toList();
    }
    push({'type': 'archived', 'archivedSessionIds': archived});
    return RpcOk({'archivedSessionIds': archived});
  }
}

/// Pending requests fixed for a test.
class FixedPending extends PendingInteractionsController {
  FixedPending(this.initial);

  final Map<String, PendingKind> initial;

  @override
  Map<String, PendingKind> build() => initial;
}

/// Stored drawer view of 本机, as shared preferences hold it.
Map<String, Object> storedView(DrawerView view) => {'drawer.view.local.local': jsonEncode(view.toJson())};

/// Two folders over the golden harness' sample conversations: 工作 (blue)
/// holds s3 and s4, 学习 (green, closed) holds s7.
const sampleFolders = DrawerView(
  loaded: true,
  folders: [
    DrawerFolder(id: 'f1', name: '工作', tint: 0, sessionIds: ['s3', 's4']),
    DrawerFolder(id: 'f2', name: '学习', tint: 5, collapsed: true, sessionIds: ['s7']),
  ],
);

bool _emojiLoaded = false;

/// Noto Color Emoji under the family [FolderMarkGlyph] names as a fallback,
/// when the machine has it.
Future<void> loadEmojiFont() async {
  if (_emojiLoaded) return;
  _emojiLoaded = true;
  final file = File('/usr/share/fonts/noto/NotoColorEmoji.ttf');
  if (!file.existsSync()) return;
  final loader = FontLoader('Noto Color Emoji')..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
  await loader.load();
}
