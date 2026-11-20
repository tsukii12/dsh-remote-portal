// A realistic shared conversation for the replay goldens and the web preview:
// a prompt with a picture, thinking, reads and a search, a reply with code,
// an edit, a test run, the answer, a todo list and a goal.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/share_code/conversation_share.dart';

final richStart = DateTime.utc(2026, 10, 24, 14, 2);

/// A 96×60 PNG (a soft gradient with a button), so the bubble's picture
/// decodes.
final richPicture = Uint8List.fromList(
  base64Decode(
    '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',
  ),
);

ConversationAsset richAsset() => ConversationAsset.of(richPicture, mediaType: 'image/png', width: 96, height: 60);

ConversationShare richConversation() {
  final picture = richAsset();
  return ConversationShare(
    title: '修复登录重复提交',
    start: richStart,
    model: 'deepseek-v4-pro',
    app: 'dsh-go 1.0.0',
    created: DateTime.utc(2026, 10, 25, 3),
    entries: [
      const TurnEntry(t: 0, d: 96000, end: 'completed', steps: 5, tokens: 48210),
      UserEntry(
        t: 120,
        text: '登录按钮连点会重复提交，帮我看看是哪里的问题，顺便修一下。',
        images: [ImageRef(id: picture.id, width: 96, height: 60, name: '截图.png')],
      ),
      const ReplyEntry(
        t: 2400,
        d: 2600,
        thinking: '用户说登录会重复提交。先看 login_controller 里 submit 的写法，再找调用点。',
        text: '先看一下登录控制器和相关的调用点。',
        model: 'deepseek-v4-pro',
      ),
      const TodosEntry(
        t: 5100,
        items: [
          (text: '找到重复提交的原因', status: 'in_progress'),
          (text: '修复 submit()', status: 'pending'),
          (text: '跑登录相关测试', status: 'pending'),
        ],
      ),
      const ToolEntry(
        t: 5200,
        d: 180,
        name: 'read',
        verb: '读取',
        summary: 'app/lib/auth/login_controller.dart',
        args: {'file_path': '/root/workspace/app/lib/auth/login_controller.dart'},
        result:
            'class LoginController {\n  Future<void> submit() async {\n    await _api.login(email, password);\n  }\n}',
      ),
      const ToolEntry(
        t: 5400,
        d: 420,
        name: 'grep',
        verb: '搜索',
        summary: r'submit\( · app/lib',
        args: {'pattern': r'submit\(', 'path': '/root/workspace/app/lib'},
        result: 'app/lib/auth/login_page.dart:48:  onPressed: controller.submit,',
      ),
      const ReplyEntry(
        t: 9000,
        d: 9000,
        model: 'deepseek-v4-pro',
        text:
            '**原因**：提交按钮只在请求返回后才禁用，两次点击之间的 `await` 让第二次点击也进了 `submit()`。\n\n'
            '修复思路：\n\n'
            '1. 进入 `submit()` 时立刻置 `_submitting = true`\n'
            '2. 请求结束后在 `finally` 里复位\n\n'
            '```dart\n'
            'Future<void> submit() async {\n'
            '  if (_submitting) return;\n'
            '  _submitting = true;\n'
            '  try {\n'
            '    await _api.login(email, password);\n'
            '  } finally {\n'
            '    _submitting = false;\n'
            '  }\n'
            '}\n'
            '```',
      ),
      const ToolEntry(
        t: 18500,
        d: 300,
        name: 'edit',
        verb: '编辑',
        summary: 'app/lib/auth/login_controller.dart',
        args: {
          'file_path': '/root/workspace/app/lib/auth/login_controller.dart',
          'old_string': '  Future<void> submit() async {\n    await _api.login(email, password);\n  }',
          'new_string': '  Future<void> submit() async {\n    if (_submitting) return;\n    _submitting = true;\n    try {\n      await _api.login(email, password);\n    } finally {\n      _submitting = false;\n    }\n  }',
        },
        result: 'ok',
      ),
      const TodosEntry(
        t: 18900,
        items: [
          (text: '找到重复提交的原因', status: 'completed'),
          (text: '修复 submit()', status: 'completed'),
          (text: '跑登录相关测试', status: 'in_progress'),
        ],
      ),
      const ToolEntry(
        t: 19200,
        d: 41000,
        name: 'bash',
        verb: '运行',
        summary: 'flutter test test/auth',
        args: {'command': 'flutter test test/auth'},
        result: '00:12 +18: All tests passed!',
      ),
      const TodosEntry(
        t: 60400,
        items: [
          (text: '找到重复提交的原因', status: 'completed'),
          (text: '修复 submit()', status: 'completed'),
          (text: '跑登录相关测试', status: 'completed'),
        ],
      ),
      const GoalEntry(t: 61000, text: '登录不再重复提交', phase: 'active'),
      const ReplyEntry(
        t: 62000,
        d: 6000,
        model: 'deepseek-v4-pro',
        thinking: '测试都过了，总结一下改动。',
        text: '改好了，18 个登录测试全部通过。现在连点只会发出一次请求，请求结束后按钮恢复可点。',
      ),
    ],
  );
}

/// The `.dshgo` text of [richConversation], with its picture.
String richFileText() => encodeConversationFile(richConversation(), [richAsset()]);
