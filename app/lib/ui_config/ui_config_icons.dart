// The icon names a ui.json custom header button may use, each bound to an
// `AppIcons` role (glyphs of the app's own icon font).

import 'package:flutter/widgets.dart' show IconData;

import '../ui/theme/app_icons.dart';

/// `UiSchema.icons` → glyph. test/ui_config/schema_sync_test.dart checks that
/// every schema name has one.
const uiConfigIcons = <String, IconData>{
  'bolt': AppIcons.running,
  'star': AppIcons.favorite,
  'sparkle': AppIcons.generating,
  'heart': AppIcons.postLike,
  'flag': AppIcons.goal,
  'bookmark': AppIcons.bookmark,
  'pin': AppIcons.pin,
  'bell': AppIcons.notifications,
  'clock': AppIcons.time,
  'alarm': AppIcons.alarmClock,
  'calendar': AppIcons.calendar,
  'todo': AppIcons.todo,
  'note': AppIcons.write,
  'document': AppIcons.document,
  'folder': AppIcons.folder,
  'search': AppIcons.search,
  'code': AppIcons.code,
  'terminal': AppIcons.terminal,
  'globe': AppIcons.web,
  'chart': AppIcons.chart,
  'lightbulb': AppIcons.tip,
  'book': AppIcons.skill,
  'puzzle': AppIcons.plugin,
  'robot': AppIcons.bot,
  'chat': AppIcons.chat,
  'mail': AppIcons.mail,
  'translate': AppIcons.translate,
  'image': AppIcons.image,
  'camera': AppIcons.camera,
  'mic': AppIcons.voice,
  'link': AppIcons.link,
  'summary': AppIcons.summary,
  'wrench': AppIcons.tool,
  'bug': AppIcons.bug,
  'travel': AppIcons.travel,
  'school': AppIcons.school,
  'home': AppIcons.home,
  'play': AppIcons.play,
  'refresh': AppIcons.refresh,
  'archive': AppIcons.archive,
  'team': AppIcons.team,
  'wallet': AppIcons.balance,
  'palette': AppIcons.theme,
};

/// The glyph for a validated icon name.
IconData uiConfigIcon(String name) => uiConfigIcons[name] ?? AppIcons.running;
