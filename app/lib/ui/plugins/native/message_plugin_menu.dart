// The plugins' items in a reply's long-press menu
// (docs/design/native-plugins.md §3.3 `message.actions`): one group per plugin,
// under its name, after the menu's own rows. A tap goes to the plugin with the
// reply's id; what comes back runs within 3 s.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';

import '../../../plugins/native/native_state.dart';
import '../../../state/chat_state.dart';
import '../../chat/widgets/message_menu.dart';
import '../../theme/app_icons.dart';
import 'native_taps.dart';

/// The plugin groups of [item]'s menu: none outside the chat screen, for a
/// reply the host hasn't saved yet, or without plugins.
List<MenuGroup> nativeMessageMenuGroups(BuildContext context, AssistantChatItem item, {String? text}) {
  final scope = NativeComposerScope.of(context);
  final sessionId = scope?.host.sessionId;
  if (scope == null || sessionId == null) return const [];
  final ref = scope.ref;
  final plugins = ref.read(nativeMessageActionsProvider);
  if (plugins.isEmpty) return const [];
  final messageId = ref.read(chatProvider(sessionId).notifier).replyMessageId(item);
  if (messageId == null) return const [];
  final target = DshGoScope(sessionId: sessionId, messageId: messageId);
  return [
    for (final plugin in plugins)
      MenuGroup(
        title: ref.read(nativePluginTitleProvider(plugin.package)),
        items: [
          for (final action in plugin.messageActions)
            MenuItem(
              icon: action.icon ?? AppIcons.plugin,
              label: action.label,
              onTap: () {
                // The reply's own context may be gone by now (the list
                // rebuilt); the chat screen's stays.
                final host = scope.host.context;
                if (host == null || !host.mounted) return;
                unawaited(runNativeAction(host, ref, action, scope: target, message: text, composer: scope.host));
              },
            ),
        ],
      ),
  ];
}
