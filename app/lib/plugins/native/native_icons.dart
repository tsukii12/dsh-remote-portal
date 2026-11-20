// The icon names a native plugin may use (protocol IconName,
// docs/design/native-plugins-protocol.md §1.1), each bound to an `AppIcons`
// role: ui.json's names, then the words plugins reach for
// (docs/design/plugin-ui-v3.md §4.3). One table for the manifest (capsules,
// menus, panels) and for views (list rows, buttons). An unknown name draws
// nothing special: the caller's generic glyph.
//
// Deliberately absent: locks, keys, shields, fingerprints, approvals and
// permissions. A plugin's surface must not look like the app asking for
// trust.

import 'package:flutter/widgets.dart' show IconData;

import '../../ui/theme/app_icons.dart';
import '../../ui_config/ui_config_icons.dart';

/// Name → glyph, after ui.json's table.
const _more = <String, IconData>{
  // Money and reading.
  'coin': AppIcons.balance,
  'money': AppIcons.balance,
  'speaker': AppIcons.readText,
  'read': AppIcons.readText,
  // Editing and sharing.
  'copy': AppIcons.copy,
  'quote': AppIcons.quote,
  'share': AppIcons.share,
  'edit': AppIcons.edit,
  'write': AppIcons.write,
  'save': AppIcons.save,
  'paste': AppIcons.paste,
  'add': AppIcons.add,
  'remove': AppIcons.remove,
  'delete': AppIcons.delete,
  'clear': AppIcons.clear,
  'fork': AppIcons.fork,
  'regenerate': AppIcons.regenerate,
  'reply': AppIcons.reply,
  'select-text': AppIcons.selectText,
  'qr': AppIcons.qrCode,
  'download': AppIcons.download,
  'downloads': AppIcons.downloads,
  'external': AppIcons.openExternal,
  // State.
  'info': AppIcons.info,
  'warning': AppIcons.warning,
  'check': AppIcons.done,
  'done': AppIcons.done,
  'success': AppIcons.success,
  'error': AppIcons.error,
  'question': AppIcons.question,
  'pending': AppIcons.pending,
  'running': AppIcons.running,
  'tip': AppIcons.tip,
  // Layout.
  'list': AppIcons.todo,
  'table': AppIcons.spreadsheet,
  'panel': AppIcons.panel,
  'sidebar': AppIcons.sidebar,
  'menu': AppIcons.menu,
  'more': AppIcons.more,
  'expand': AppIcons.expand,
  'collapse': AppIcons.collapse,
  // Files and media.
  'file': AppIcons.file,
  'folder-open': AppIcons.folderOpen,
  'workspace': AppIcons.workspace,
  'storage': AppIcons.phoneStorage,
  'pdf': AppIcons.pdf,
  'zip': AppIcons.zip,
  'slides': AppIcons.slides,
  'article': AppIcons.article,
  'text': AppIcons.plainText,
  'diff': AppIcons.diff,
  'gallery': AppIcons.gallery,
  'audio': AppIcons.audio,
  'music': AppIcons.audioFile,
  'video': AppIcons.video,
  'video-file': AppIcons.videoFile,
  'play-video': AppIcons.playVideo,
  'pause': AppIcons.pause,
  'stop': AppIcons.stop,
  'replay': AppIcons.replay,
  'generate-image': AppIcons.generateImage,
  'generate-video': AppIcons.generateVideo,
  'diagram': AppIcons.diagram,
  // Agents and work.
  'plugin': AppIcons.plugin,
  'bot': AppIcons.bot,
  'agent': AppIcons.subagents,
  'skill': AppIcons.skill,
  'model': AppIcons.model,
  'tool': AppIcons.tool,
  'workflow': AppIcons.workflow,
  'goal': AppIcons.goal,
  'plan': AppIcons.plan,
  'job': AppIcons.jobs,
  'automation': AppIcons.automation,
  'command': AppIcons.command,
  'trajectory': AppIcons.trajectory,
  'web': AppIcons.web,
  'web-search': AppIcons.webSearch,
  'browser': AppIcons.browser,
  // Time.
  'history': AppIcons.history,
  'time': AppIcons.time,
  'today': AppIcons.today,
  'timezone': AppIcons.timeZone,
  'schedule': AppIcons.scheduled,
  'repeat': AppIcons.recurring,
  'reminder': AppIcons.reminder,
  // People and messages.
  'user': AppIcons.profile,
  'account': AppIcons.account,
  'group': AppIcons.groupChat,
  'chats': AppIcons.conversations,
  'mention': AppIcons.mention,
  'invite': AppIcons.invite,
  'announcement': AppIcons.announcement,
  'reaction': AppIcons.reaction,
  'poll': AppIcons.poll,
  'notification': AppIcons.notifications,
  'send': AppIcons.send,
  'community': AppIcons.community,
  'forum': AppIcons.forum,
  'feedback': AppIcons.feedback,
  'wechat': AppIcons.wechat,
  'qq': AppIcons.qq,
  'telegram': AppIcons.telegram,
  'discord': AppIcons.discord,
  // Devices and hosts.
  'phone': AppIcons.thisPhone,
  'computer': AppIcons.computer,
  'cloud': AppIcons.cloud,
  'server': AppIcons.remoteHost,
  'power': AppIcons.power,
  'restart': AppIcons.restart,
  'retry': AppIcons.retry,
  // Look and feel.
  'theme': AppIcons.theme,
  'color': AppIcons.color,
  'text-size': AppIcons.textSize,
  'pet': AppIcons.pet,
  'featured': AppIcons.featured,
  'badge': AppIcons.badgeEarned,
  'favorite': AppIcons.favorite,
  'settings': AppIcons.configure,
};

/// Every name a plugin may use, ui.json's first, in table order (the SDK's
/// view schema lists the same, `schema_sync_test`).
final nativeIconNames = List<String>.unmodifiable([...uiConfigIcons.keys, ..._more.keys]);

/// The glyph for a plugin's icon [name]; null when the name is unknown.
IconData? nativeIcon(String? name) {
  if (name == null || name.isEmpty) return null;
  return uiConfigIcons[name] ?? _more[name];
}
