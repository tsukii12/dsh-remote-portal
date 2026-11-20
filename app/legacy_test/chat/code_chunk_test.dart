import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Iterable<TextSpan> leaves(TextSpan span) sync* {
  if (span.children == null) {
    yield span;
    return;
  }
  for (final child in span.children!) {
    if (child is TextSpan) yield* leaves(child);
  }
}

void main() {
  test('large code keeps colors through the tail and reuses completed chunks', () {
    final code = List.generate(
      700,
      (i) => i % 205 == 204 ? '' : 'final value$i = "a reasonably long string value";',
    ).join('\n');
    expect(code.length, greaterThan(30000));
    final span = highlightCode(code, 'dart', Brightness.light);
    final blocks = span.children!.cast<TextSpan>();
    expect(blocks.length, greaterThan(1));
    expect(leaves(blocks.last).where((span) => span.style?.color != null), isNotEmpty);
    final next = highlightCode('$code\nfinal tail = 42;', 'dart', Brightness.light);
    for (var i = 0; i < blocks.length - 1; i++) {
      expect(next.children![i], same(blocks[i]));
    }
    expect(codeChunks(code).join(), code);
  });
  test('preferred cuts do not break block comments or triple quoted strings', () {
    for (final (open, close) in [('/*', '*/'), ('"""', '"""')]) {
      final prefix = List.filled(190, 'final x = 1;\n').join();
      final body = '$open\n${List.filled(20, 'inside\n').join()}\ntopLevelInside\n$close\n\n';
      final source = '$prefix${body}final outside = 2;\n';
      final chunks = codeChunks(source);
      expect(chunks.first, contains('topLevelInside\n$close'));
      expect(chunks.join(), source);
    }
  });
  test('short code stays one span and the complete result is cached', () {
    const code = 'final answer = 42;';
    expect(codeChunks(code), [code]);
    expect(highlightCode(code, 'dart', Brightness.dark), same(highlightCode(code, 'dart', Brightness.dark)));
  });
}
