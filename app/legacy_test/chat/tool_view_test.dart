import 'dart:convert';

import 'package:dsh_app/ui/chat/render/ansi_text.dart';
import 'package:dsh_app/ui/chat/render/diff_view.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

void main() {
  test('bash shows its command; file tools show a workspace-relative path', () {
    final bash = ToolView.of(tool('a', 'bash', {'command': 'flutter  test\n  --x'}));
    expect(bash.verb, '运行');
    expect(bash.summary, 'flutter test --x');
    expect(bash.summaryIsCode, isTrue);

    final read = ToolView.of(tool('b', 'read', {'file_path': '/root/workspace/app/lib/main.dart'}));
    expect(read.verb, '读取');
    expect(read.summary, 'app/lib/main.dart');
  });

  test('command is recovered from arguments that are still streaming', () {
    const partial = ToolChatItem(
      callId: 'c',
      name: 'bash',
      arguments: '{"command": "echo \\"hi\\" && ls -',
      status: ToolStatus.streaming,
    );
    final view = ToolView.of(partial);
    expect(view.args, isNull);
    expect(view.command, 'echo "hi" && ls -');
  });

  test('arguments are parsed once they can be a whole object, and only then', () {
    ToolView view(String arguments) =>
        ToolView.of(ToolChatItem(callId: 'c', name: 'bash', arguments: arguments, status: ToolStatus.streaming));
    // Every prefix of a streamed object: parsed exactly when jsonDecode would give a map.
    const whole = '{"command": "ls", "options": {"all": true, "depth": 2}, "tags": ["a"]} \n';
    for (var end = 0; end <= whole.length; end++) {
      final prefix = whole.substring(0, end);
      Object? decoded;
      try {
        decoded = jsonDecode(prefix);
      } on FormatException {
        decoded = null;
      }
      expect(view(prefix).args, decoded is Map<String, Object?> ? decoded : isNull, reason: prefix);
    }
    expect(view('[1, 2]').args, isNull);
    expect(view('{"a": 1} ').args, isNull, reason: 'not JSON whitespace');
    expect(view(' {"a": 1}\t').args, {'a': 1});
  });

  test('the Android sandbox refusal is recognised', () {
    final view = ToolView.of(tool('c', 'bash', {'command': 'ls'}, status: ToolStatus.failed, result: sandboxRefusal));
    expect(view.sandboxBlocked, isTrue);

    final other = ToolView.of(tool('d', 'bash', {'command': 'ls'}, status: ToolStatus.failed, result: 'boom'));
    expect(other.sandboxBlocked, isFalse);
    expect(other.failureText, 'boom');
  });

  test('edit diff comes from result meta, else from the arguments', () {
    final fromMeta = ToolView.of(
      tool(
        'e',
        'edit',
        {'file_path': 'a.dart', 'old_string': 'x', 'new_string': 'y'},
        meta: {
          'diffs': [
            {'path': 'a.dart', 'oldText': 'a\nb\nc', 'newText': 'a\nB\nc\nd'},
          ],
        },
      ),
    );
    expect(fromMeta.diffCounts, (added: 2, removed: 1));

    final fromArgs = ToolView.of(tool('f', 'edit', {'file_path': 'a.dart', 'old_string': 'x', 'new_string': 'y\nz'}));
    expect(fromArgs.diffCounts, (added: 2, removed: 1));
    expect(fromArgs.diff!.first.kind, DiffLineKind.del);
  });

  test('read window comes from meta lines or the numbered result text', () {
    final fromText = ToolView.of(
      tool(
        'r',
        'read',
        {'file_path': '/root/workspace/main.py'},
        result:
            '<path>main.py</path>\n<content>\n7: import os\n8: print(1)\n\n'
            '(End of file - total 8 lines)\n</content>',
      ),
    );
    final window = fromText.readWindow!;
    expect(window.firstLine, 7);
    expect(window.code, 'import os\nprint(1)');
    expect(window.language, 'python');
  });

  test('the view is reused while its inputs are unchanged', () {
    final item = tool('a', 'bash', {'command': 'ls'}, result: 'x');
    final first = ToolView.of(item);
    expect(ToolView.of(item, first), same(first));
    final changed = tool('a', 'bash', {'command': 'ls -la'}, result: 'x');
    expect(ToolView.of(changed, first), isNot(same(first)));
  });

  test('ANSI parsing colours SGR runs and strips other escapes', () {
    final palette = List.generate(16, (i) => Color(0xFF000000 + i));
    final span = parseAnsi('\x1B]0;title\x07\x1B[2Kplain \x1B[31mred\x1B[0m done', const TextStyle(), palette);
    expect(span.toPlainText(), 'plain red done');
    final red = (span.children!).cast<TextSpan>().firstWhere((s) => s.text == 'red');
    expect(red.style!.color, palette[1]);
    expect(stripAnsi('\x1B[1mbold\x1B[0m'), 'bold');
  });
}
