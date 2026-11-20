import 'package:dsh_app/forum/render/cooked.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final validCode = encodeShareCode(const ProfileShare(name: 'valid profile'));
  final valid = ShareLink.inline(ShareKind.profile, validCode);

  for (final entry in <String, String>{
    'query': 'dshgo://share/profile?p=%FF',
    'fragment': '$shareLandingUrl#p=%FF',
    'path': 'dshgo://share/pro%FFfile?p=$validCode',
  }.entries) {
    test('parse rejects non-UTF8 ${entry.key} without throwing', () {
      // These are structurally valid URIs. The bad bytes appear only when
      // percent-encoded components are decoded as UTF-8 by ShareLink.parse.
      final uri = Uri.tryParse(entry.value);
      expect(uri, isNotNull);
      expect(ShareLink.parse(uri!), isNull);
    });
  }

  test('find continues from a malformed candidate to a valid share link', () {
    final found = ShareLink.find('broken dshgo://share/profile?p=%FF\nvalid ${valid.appLink}');
    expect(found, isNotNull);
    expect(found!.kind, ShareKind.profile);
    expect(found.code, validCode);
  });

  test('forum cooked parsing keeps prose around a malformed share href', () {
    final blocks = parseCooked(
      '<p>before <a href="$shareLandingUrl#p=%FF">broken link</a> after</p>',
      base: Uri.parse('https://forum.example/'),
    );
    expect(blocks.whereType<CookedShare>(), isEmpty);
    final prose = blocks.whereType<CookedMarkdown>().map((block) => block.markdown).join('\n');
    expect(prose, contains('before'));
    expect(prose, contains('broken link'));
    expect(prose, contains('after'));
  });
}
