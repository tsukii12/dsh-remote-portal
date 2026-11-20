import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

List<(String, String, bool)> _parts(String text, {int limit = 4000, bool running = false}) => [
  for (final f in reasoningFragments(text, running: running, maxTextChars: limit)) (f.text, f.suffix, f.complete),
];

void main() {
  test('word boundaries preserve their whitespace and the growing tail', () {
    expect(_parts('ab cd ef', limit: 4, running: true), [('ab', ' ', true), ('cd', ' ', true), ('ef', '', false)]);
    expect(_parts('word    tail', limit: 4), [('word', '    ', true), ('tail', '', true)]);
  });

  test('paragraph separators and the empty piece after consumed whitespace remain exact', () {
    expect(_parts('word    \n\n  tail', limit: 4, running: true), [
      ('word', '    ', true),
      ('', '\n\n', true),
      ('  ta', '', true),
      ('il', '', false),
    ]);
    expect(_parts('ab\r\n \t\r\ncd', limit: 4), [('ab', '\r\n \t\r\n', true), ('cd', '', true)]);
  });

  test('a supplementary character spanning a cut stays together', () {
    expect(_parts('a😀b', limit: 2), [('a', '', true), ('😀', '', true), ('b', '', true)]);
    expect(_parts('ab😀cd', limit: 3, running: true), [('ab', '', true), ('😀c', '', true), ('d', '', false)]);
  });

  test('unpaired UTF-16 units are preserved without normalizing the source', () {
    expect(_parts('a\uD800b', limit: 2), [('a', '', true), ('\uD800b', '', true)]);
    expect(_parts('\uDC00ab', limit: 2), [('\uDC00a', '', true), ('b', '', true)]);
  });

  test('empty and exact-budget text retain the final completion flag', () {
    expect(_parts('', running: true), [('', '', false)]);
    expect(_parts(''), [('', '', true)]);
    expect(_parts('abcd', limit: 4, running: true), [('abcd', '', false)]);
    expect(_parts('abcd\n\n', limit: 4, running: true), [('abcd', '\n\n', true), ('', '', false)]);
  });

  test('long paragraphs reconstruct every UTF-16 unit at the default request budget', () {
    for (final source in [
      'Thinking through this step carefully. ' * 8192,
      '😀 word\u00A0中文\t' * 16384,
      '${'x' * 4000}${' \t\u00A0' * 5000}tail',
    ]) {
      for (final running in [false, true]) {
        final fragments = reasoningFragments(source, running: running, maxTextChars: 4000);
        expect(fragments.map((f) => f.text + f.suffix).join(), source);
        expect(fragments.every((f) => f.text.length <= 4000), isTrue);
        expect(fragments.take(fragments.length - 1).every((f) => f.complete), isTrue);
        expect(fragments.last.complete, !running);
      }
    }
  });
}
