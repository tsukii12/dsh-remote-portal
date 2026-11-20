import 'package:flutter/widgets.dart';

import 'dsh_ui_reply.dart';

/// 发一条用户消息；送不出去时返回 false（视图恢复成可点）。
typedef DshUiSend = Future<bool> Function(String text);

/// 一条助手消息里的视图要的上下文。`MarkdownBody` 的 `codeBuilder` 必须是
/// 静态 tear-off（gpt_markdown 按身份比较配置），所以交互需要的东西由
/// `AssistantMessage` 外面包的这一层提供，`DshUiBlock` 从 context 里读。
///
/// 没有它时视图只读展示（例如在别的页面里预览一段 Markdown）。
class DshUiScope extends InheritedWidget {
  const DshUiScope({
    super.key,
    required this.sessionId,
    required this.messageId,
    required this.state,
    this.onReply,
    this.onAskResend,
    required super.child,
  });

  final String sessionId;

  /// 这条助手消息的 id（`AssistantChatItem.id`）。
  final String messageId;

  /// 由 `dshUiStateFor` 从消息顺序推出来的交互状态。
  final DshUiState state;

  /// 用户点了选项 / 确认：发出 `[dsh-ui reply]` 消息（`ChatController.send`）。
  final DshUiSend? onReply;

  /// 视图格式有误时「让它重发」：发出一条说明错误的消息。
  final DshUiSend? onAskResend;

  static DshUiScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DshUiScope>();

  @override
  bool updateShouldNotify(DshUiScope old) =>
      old.sessionId != sessionId ||
      old.messageId != messageId ||
      old.state != state ||
      old.onReply != onReply ||
      old.onAskResend != onAskResend;
}
