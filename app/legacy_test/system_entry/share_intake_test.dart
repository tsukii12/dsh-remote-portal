import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/share');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IncomingShare.parse', () {
    test('reads text, files and what was skipped', () {
      final share = IncomingShare.parse({
        'text': '看看这个',
        'subject': null,
        'files': [
          {'path': '/c/share/1/报价单.pdf', 'name': '报价单.pdf', 'mime': 'application/pdf', 'size': 1200},
          {'path': '/c/share/1/IMG_1.jpg', 'name': 'IMG_1.jpg', 'mime': 'image/jpeg'},
          {'path': '', 'name': 'broken'},
        ],
        'skipped': [
          {'name': 'movie.mp4', 'reason': 'too_large'},
          {'name': null, 'reason': 'too_many'},
          {'reason': 'whatever'},
        ],
      })!;
      expect(share.text, '看看这个');
      expect(share.subject, isNull);
      expect(share.files.map((f) => f.name), ['报价单.pdf', 'IMG_1.jpg']);
      expect(share.files.first.size, 1200);
      expect(share.skipped.map((s) => s.reason), [
        ShareSkipReason.tooLarge,
        ShareSkipReason.tooMany,
        ShareSkipReason.unreadable,
      ]);
      expect(share.skipped.first.name, 'movie.mp4');
    });

    test('ignores malformed and empty arrivals', () {
      expect(IncomingShare.parse(null), isNull);
      expect(IncomingShare.parse('text'), isNull);
      expect(IncomingShare.parse({'text': '', 'files': []}), isNull);
      expect(IncomingShare.parse({'files': 'nope', 'skipped': 3}), isNull);
    });
  });

  group('composedText', () {
    test('puts a page title over a bare link', () {
      const share = IncomingShare(text: 'https://example.com/a?b=1', subject: '一篇文章');
      expect(share.composedText, '一篇文章\nhttps://example.com/a?b=1');
    });

    test('keeps text as it is otherwise', () {
      expect(const IncomingShare(text: '看看 https://a.com', subject: '标题').composedText, '看看 https://a.com');
      expect(const IncomingShare(text: '一篇文章 https://a.com', subject: '一篇文章').composedText, '一篇文章 https://a.com');
      expect(const IncomingShare(text: '  正文  ').composedText, '正文');
      // A subject next to files only (a mail subject, a file name) stays out.
      expect(
        const IncomingShare(
          subject: 'IMG_1.jpg',
          files: [SharedFile(path: '/p', name: 'IMG_1.jpg')],
        ).composedText,
        '',
      );
    });
  });

  group('share codes', () {
    test('a lone .dshgo file is a share code', () {
      const byName = IncomingShare(
        files: [SharedFile(path: '/p/读书笔记.DSHGO', name: '读书笔记.DSHGO')],
      );
      const byType = IncomingShare(
        files: [SharedFile(path: '/p/x', name: 'x', mime: 'application/vnd.dshgo+json')],
      );
      expect(byName.shareCodeFile?.name, '读书笔记.DSHGO');
      expect(byType.shareCodeFile, isNotNull);
    });

    test('a .dshgo among other files is just a file', () {
      const share = IncomingShare(
        files: [
          SharedFile(path: '/p/a.dshgo', name: 'a.dshgo'),
          SharedFile(path: '/p/b.png', name: 'b.png'),
        ],
      );
      expect(share.shareCodeFile, isNull);
    });

    test('a forwarded share link is found in the text', () {
      final link = ShareLink.find('dshgo://share/plugin?p=abc.def12345');
      expect(link, isNotNull);
      final share = IncomingShare(text: '试试这个插件：${link!.webLink}');
      expect(share.shareLink?.webLink, link.webLink);
      // With files it's a message about them.
      expect(
        IncomingShare(
          text: link.webLink,
          files: const [SharedFile(path: '/p', name: 'a.png')],
        ).shareLink,
        isNull,
      );
      expect(const IncomingShare(text: '没有链接').shareLink, isNull);
    });
  });

  group('ShareIntake', () {
    test('holds arrivals until the first listener and says ready once', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        call,
      ) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(
        () =>
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
      );
      final intake = ShareIntake();
      addTearDown(intake.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['ready']);

      // A push from the native side before anyone listens.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'dsh/share',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('share', {'text': '先到的'})),
        (_) {},
      );
      intake.add(const IncomingShare(text: '后到的'));
      final got = <String?>[];
      final sub = intake.shares.listen((s) => got.add(s.text));
      await Future<void>.delayed(Duration.zero);
      expect(got, ['先到的', '后到的']);
      intake.add(const IncomingShare(text: '再来'));
      await Future<void>.delayed(Duration.zero);
      expect(got.last, '再来');
      await sub.cancel();
    });

    test('without a native side there is simply nothing', () async {
      final intake = ShareIntake();
      addTearDown(intake.dispose);
      final got = <IncomingShare>[];
      final sub = intake.shares.listen(got.add);
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      await sub.cancel();
    });
  });
}
