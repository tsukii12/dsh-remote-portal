import 'dart:io';

import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

const id = 'aa5a315d61ae9438b18d';
const profile = ProfileShare(
  name: 'reader',
  skills: [
    SharedSkill(name: 'outline', files: {'SKILL.md': 'Outline first.'}),
  ],
);

void main() {
  for (final shape in ['canonical', 'bare', 'escaped key', 'escaped value']) {
    test('Gist and file read the same $shape JSON envelope', () async {
      final code = encodeShareCode(profile);
      var text = encodeShareFile(profile, code: code);
      if (shape == 'bare') text = code;
      if (shape == 'escaped key') text = text.replaceFirst('"code"', r'"\u0063ode"');
      if (shape == 'escaped value') {
        final escaped = '\\u${code.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}${code.substring(1)}';
        text = text.replaceFirst(code, escaped);
      }
      final root = await Directory.systemTemp.createTemp('gist-envelope-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File('${root.path}/profile.dshgo').writeAsString(text);
      final fromFile = decodeShareFile(await file.readAsString()) as ProfileShare;
      expect(fromFile.toJson(), profile.toJson());
      final net = FakeShareNet()..gists[id] = text;
      final link = ShareLink.gist(id, code.split('.').last);
      expect(await fetchShareLinkText(link, net), text);
      final fromGist = await resolveShareLink(link, net) as ProfileShare;
      expect(fromGist.toJson(), fromFile.toJson());
      expect(net.created, isEmpty);
    });
  }

  test('Gist checksum mismatch still fails before resolving payload', () async {
    final net = FakeShareNet()..gists[id] = encodeShareFile(profile);
    await expectLater(
      fetchShareLinkText(const ShareLink.gist(id, 'AAAAAAAA'), net),
      throwsA(isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'gist changed')),
    );
  });

  test('invalid envelope error does not poison the next valid Gist read', () async {
    final code = encodeShareCode(profile);
    final link = ShareLink.gist(id, code.split('.').last);
    final net = FakeShareNet()..gists[id] = '{"dshgo":1,"code":';
    await expectLater(resolveShareLink(link, net), throwsA(isA<ShareDecodeException>()));
    net.gists[id] = encodeShareFile(profile, code: code);
    expect((await resolveShareLink(link, net) as ProfileShare).toJson(), profile.toJson());
  });

  test('conversation-sized decoder still rejects a profile above its body budget', () {
    final code = encodeShareJson({
      'v': 1,
      'kind': 'profile',
      'settings': {
        'subagent': {'note': 'x' * maxShareBodyBytes},
      },
    });
    expect(code.length, lessThan(maxShareCodeChars));
    expect(
      () => decodeShareJson(code, large: true),
      throwsA(isA<ShareDecodeException>().having((e) => e.reason, 'reason', 'body too large')),
    );
    expect(decodeShareFile(encodeShareFile(profile)).toJson(), profile.toJson());
  });
}
