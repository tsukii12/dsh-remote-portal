import 'package:dsh_app/ui/chat/secret_mask.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a long prefixed credential reaching EOF keeps its exact span and mask', () {
    final token = 'ghp_${'A' * 65536}';
    final spans = findSecrets(token);
    expect(spans, hasLength(1));
    expect(spans.single.start, 0);
    expect(spans.single.end, token.length);
    expect(spans.single.masked, 'ghp_AAAA${'*' * 65532}');
  });

  test('an unfinished private key at EOF preserves line breaks and scalar masks', () {
    const header = '-----BEGIN PRIVATE KEY-----\n';
    final block = '${header}AB😀\n${'A' * 65536}';
    final text = 'see $block';
    final spans = findSecrets(text);
    expect(spans, hasLength(1));
    expect(spans.single.start, 4);
    expect(spans.single.end, text.length);
    expect(spans.single.masked, '$header***\n${'*' * 65536}');
  });
}
