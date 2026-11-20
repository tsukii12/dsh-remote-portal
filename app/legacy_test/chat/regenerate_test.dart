// 「重新回答」 is offered on the conversation's last reply only, for a
// prompt that can be sent again as it was (text and images; files cannot be
// read back), and re-sends the images in order with their own types.

import 'dart:typed_data';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/regenerate.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

UserChatItem _user(
  int seq,
  String text, {
  List<ImageAttachment> images = const [],
  List<FileAttachment> files = const [],
}) => UserChatItem(seq: seq, time: DateTime(2026, 10, 24, 9), text: text, images: images, files: files);

AssistantChatItem _reply(int seq, String text, {bool streaming = false}) =>
    AssistantChatItem(id: 'a$seq', seq: seq, text: text, reasoning: '', streaming: streaming);

ToolChatItem _tool(int seq) =>
    ToolChatItem(callId: 'c$seq', name: 'bash', arguments: '{}', status: ToolStatus.succeeded, seq: seq);

final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, //
]);
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]);

void main() {
  group('regenerablePrompt', () {
    final first = _user(1, '第一个问题');
    final answer = _reply(2, '第一个回答');
    final second = _user(3, '第二个问题');
    final last = _reply(5, '第二个回答');

    test('the last reply resends the prompt of its turn', () {
      final state = ChatState(loading: false, items: [first, answer, second, _tool(4), last]);
      expect(regenerablePrompt(state, last), same(second));
      // An earlier reply is not the conversation's last word.
      expect(regenerablePrompt(state, answer), isNull);
    });

    test('a notice after the reply still counts as the end', () {
      const notice = NoticeChatItem(seq: 6, kind: 'max-tokens', text: '已达到输出上限');
      final state = ChatState(loading: false, items: [second, last, notice]);
      expect(regenerablePrompt(state, last), same(second));
    });

    test('not while a turn runs, messages wait or the reply streams', () {
      expect(regenerablePrompt(ChatState(loading: false, running: true, items: [second, last]), last), isNull);
      expect(
        regenerablePrompt(
          ChatState(
            loading: false,
            items: [second, last],
            pending: [
              PendingPrompt(requestId: 'r1', text: '再看看', time: DateTime(2026, 10, 24, 9), mode: SendMode.queue),
            ],
          ),
          last,
        ),
        isNull,
      );
      final live = _reply(5, '生成中', streaming: true);
      expect(regenerablePrompt(ChatState(loading: false, items: [second, live]), live), isNull);
    });

    test('a prompt with files cannot be sent again; images can', () {
      final withFile = _user(
        3,
        '看看这个表',
        files: const [FileAttachment(attachmentId: 'f1', name: 'a.xlsx')],
      );
      expect(regenerablePrompt(ChatState(loading: false, items: [withFile, last]), last), isNull);
      final withImage = _user(
        3,
        '',
        images: const [ImageAttachment(attachmentId: 'i1', mediaType: 'image/png')],
      );
      expect(regenerablePrompt(ChatState(loading: false, items: [withImage, last]), last), same(withImage));
    });

    test('no prompt before the reply: nothing to resend', () {
      expect(regenerablePrompt(ChatState(loading: false, items: [last]), last), isNull);
    });
  });

  test('resendImages: in order, typed from the bytes, named', () async {
    final prompt = _user(
      3,
      '对比这两张',
      images: const [
        ImageAttachment(attachmentId: 'i1', mediaType: 'image/png', name: '截图.png'),
        // Stored as PNG by its record, JPEG by its bytes: the bytes win.
        ImageAttachment(attachmentId: 'i2', mediaType: 'image/png'),
      ],
    );
    final asked = <String>[];
    final drafts = await resendImages(prompt, (image) async {
      asked.add(image.attachmentId);
      return image.attachmentId == 'i1' ? _png : _jpeg;
    });
    expect(asked, ['i1', 'i2']);
    expect([for (final d in drafts) d.name], ['截图.png', 'image-2.jpg']);
    expect([for (final d in drafts) d.mediaType], ['image/png', 'image/jpeg']);
    expect(drafts.every((d) => d.isImage), isTrue);
    expect(drafts.last.bytes, _jpeg);
  });

  test('resendImages passes a failed read on', () async {
    final prompt = _user(
      3,
      '看图',
      images: const [ImageAttachment(attachmentId: 'gone', mediaType: 'image/png')],
    );
    expect(resendImages(prompt, (_) async => throw StateError('未连接')), throwsStateError);
  });
}
