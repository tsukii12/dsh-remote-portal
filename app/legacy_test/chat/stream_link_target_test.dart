import 'package:dsh_app/ui/chat/render/stream_repair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (name, source, expected) in [
    ('closed target before emphasis', '前[链接](x) **后', '前[链接](x) **后**'),
    ('newline before a later parenthesis', '前[链接](x\nlater)', '前[链接](#)'),
    ('newline without a later parenthesis', '前[链接](x\n后文', '前[链接](#)'),
    ('unfinished image before newline', '前![图](x\nlater)', '前'),
    ('closed image before newline', '前![图](x)\n**后', '前![图](x)\n**后**'),
    ('empty closed target', '[label]() **后', '[label]() **后**'),
    ('only the final target is incomplete', '[a](1)[b](2)[c](3', '[a](1)[b](2)[c](#)'),
    ('CRLF target boundary', '[label](x\r\n)', '[label](#)'),
    ('Unicode separator keeps the existing target rule', '[文](x\u2028y) **后', '[文](x\u2028y) **后**'),
    ('bare carriage return keeps the existing target rule', '[文](x\ry) **后', '[文](x\ry) **后**'),
  ]) {
    test(name, () {
      expect(repairStreamingMarkdown(source), expected);
      final repair = StreamingMarkdownRepair();
      for (var end = 0; end <= source.length; end++) {
        final prefix = source.substring(0, end);
        expect(repair.repair(prefix), repairStreamingMarkdown(prefix));
      }
      expect(repair.repair(source), expected);
    });
  }
}
