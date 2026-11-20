/// 可交互回复（dsh-ui）：模型在回复里写 ```` ```dsh-ui ```` 围栏，里面是一份
/// JSON 蓝图，App 用原生组件画出来。
///
/// 接入点：
/// - `MarkdownBody._codeBuilder`：语言是 `dsh-ui` 时返回 [DshUiBlock]；
/// - `MarkdownBody.repairBareViews`：模型忘了写围栏时，裸 JSON 也按视图画
///   （[fenceBareDshUiViews] 补围栏）；
/// - `AssistantMessage` 外面包 [DshUiScope]（状态用 [dshUiStateFor] 推）；
/// - 用户气泡：[parseDshUiReply] 认出回复，画 [DshUiReply.chipLabel]；
/// - 复制 / 分享 / 导出：[dshUiPlainText] 把块换成一行摘要。
library;

export 'dsh_ui_block.dart' show DshUiBlock, DshUiFallback, dshUiReplyChip;
export 'dsh_ui_model.dart';
export 'dsh_ui_reply.dart';
export 'dsh_ui_reply_chip.dart';
export 'dsh_ui_scope.dart';
export 'dsh_ui_skeleton.dart' show DshUiSkeleton, guessDshUiShape;
export 'dsh_ui_widgets.dart' show DshUiCard;
