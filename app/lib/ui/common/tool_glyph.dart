// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/semantic_colors.dart';

/// DSH 工具名 → 视觉类别 / 图标 / 默认中文动词。
///
/// 名字来自 `@deepseek-ai/dsh` 0.2.0-rc.2 内置工具包:
/// dsh-tool-bash、-pwsh、-jobs、-fs、-fs-search、-str-replace-editor、-web、
/// -todo、-goal、-ask-user、-subagent、-subagent-control、-workflow、-skill、
/// -present、-ralph。MCP 工具形如 `mcp__server__tool`。
abstract final class ToolGlyphs {
  static ToolTone toneFor(String name) => switch (name) {
    'bash' || 'pwsh' || 'job_output' || 'job_list' || 'job_kill' => ToolTone.terminal,
    'read' || 'read_image' || 'present' => ToolTone.read,
    'write' || 'edit' || 'str_replace_editor' => ToolTone.edit,
    'grep' || 'glob' => ToolTone.search,
    'web_fetch' || 'web_search' => ToolTone.web,
    'subagent' ||
    'send_message' ||
    'interrupt_agent' ||
    'list_subagent_models' ||
    'workflow' ||
    'ralph' ||
    'skill' => ToolTone.agent,
    'todo_write' || 'create_goal' || 'get_goal' || 'update_goal' || 'ask_user_question' => ToolTone.plan,
    _ => ToolTone.neutral,
  };

  static IconData iconFor(String name) => switch (name) {
    'bash' || 'pwsh' => AppIcons.terminal,
    'job_output' || 'job_list' || 'job_kill' => AppIcons.jobs,
    'read' => AppIcons.document,
    'read_image' => AppIcons.image,
    'present' => AppIcons.artifacts,
    'write' || 'edit' || 'str_replace_editor' => AppIcons.edit,
    'grep' => AppIcons.search,
    'glob' => AppIcons.folderOpen,
    'web_fetch' => AppIcons.web,
    'web_search' => AppIcons.webSearch,
    'subagent' || 'send_message' || 'interrupt_agent' => AppIcons.subagents,
    'workflow' || 'ralph' => AppIcons.workflow,
    'skill' => AppIcons.skill,
    'todo_write' => AppIcons.todo,
    'create_goal' || 'get_goal' || 'update_goal' => AppIcons.goal,
    'ask_user_question' => AppIcons.question,
    _ when name.startsWith('mcp__') => AppIcons.plugin,
    _ => AppIcons.tool,
  };

  /// 工具行标题的默认动词。业务层有更具体的摘要时可以覆盖。
  static String labelFor(String name) => switch (name) {
    'bash' || 'pwsh' => appL10n.botsGlyphRun,
    'job_output' => appL10n.botsGlyphJobOutput,
    'job_list' => appL10n.botsGlyphJobs,
    'job_kill' => appL10n.botsGlyphStopJob,
    'read' => appL10n.botsGlyphRead,
    'read_image' => appL10n.botsGlyphImage,
    'present' => appL10n.botsGlyphDeliver,
    'write' => appL10n.botsGlyphWrite,
    'edit' || 'str_replace_editor' => appL10n.commonEdit,
    'grep' => appL10n.botsGlyphSearch,
    'glob' => appL10n.botsGlyphFindFiles,
    'web_fetch' => appL10n.botsGlyphOpenWeb,
    'web_search' => appL10n.botsGlyphWebSearch,
    'subagent' => appL10n.botsGlyphSubagent,
    'send_message' => appL10n.botsGlyphMessageAgent,
    'interrupt_agent' => appL10n.botsGlyphInterruptAgent,
    'list_subagent_models' => appL10n.botsGlyphListModels,
    'workflow' => appL10n.botsGlyphWorkflow,
    'ralph' => appL10n.botsGlyphLoop,
    'skill' => appL10n.botsGlyphSkill,
    'todo_write' => appL10n.botsGlyphTodo,
    'create_goal' => appL10n.botsGlyphSetGoal,
    'get_goal' => appL10n.botsGlyphViewGoal,
    'update_goal' => appL10n.botsGlyphUpdateGoal,
    'ask_user_question' => appL10n.botsGlyphAsk,
    _ when name.startsWith('mcp__') => name.split('__').last,
    _ => name,
  };
}

/// 工具类别小图标块:连续圆角方块 + 类别色。
///
/// 方块而不是圆:圆形头像是"人"的语言,工具是"操作"。
/// 尺寸默认 22,对齐 DSH 官方 24px 单行工具行;卡片头可以用 32。
class ToolGlyph extends StatelessWidget {
  const ToolGlyph({super.key, required this.name, this.size = 22});

  /// DSH 工具名(如 `bash`、`str_replace_editor`、`mcp__github__search`)。
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = DshColors.of(context).tool(ToolGlyphs.toneFor(name));
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: background,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(size * 0.32))),
        ),
        child: Icon(ToolGlyphs.iconFor(name), size: size * 0.6, color: foreground),
      ),
    );
  }
}
