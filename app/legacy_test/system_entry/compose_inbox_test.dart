import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
);

DraftAttachment _image(String name) => DraftAttachment.sniff(name, _png);

DraftAttachment _file(String name) => DraftAttachment.sniff(name, Uint8List.fromList(utf8.encode('内容')));

class _Drafts extends DraftStore {
  _Drafts(this.initial);
  final DraftState initial;

  @override
  DraftState build() => initial;

  void load() => state = DraftState(drafts: state.drafts, loaded: true);
}

void main() {
  group('fromShare', () {
    test('reads the files, keeps the text, and lists what did not come', () async {
      final read = <String>[];
      final request = await ComposeRequest.fromShare(
        const IncomingShare(
          text: 'https://example.com/a',
          subject: '报价',
          files: [
            SharedFile(path: '/c/1/a.png', name: 'a.png'),
            SharedFile(path: '/c/1/报价单.pdf', name: '报价单.pdf'),
            SharedFile(path: '/c/1/gone.txt', name: 'gone.txt'),
            SharedFile(path: '/c/1/empty.txt', name: 'empty.txt'),
          ],
          skipped: [SkippedShare(ShareSkipReason.tooLarge, 'movie.mp4')],
        ),
        read: (path) async {
          read.add(path);
          return switch (path) {
            '/c/1/a.png' => _png,
            '/c/1/报价单.pdf' => Uint8List.fromList(utf8.encode('%PDF-1.7')),
            '/c/1/empty.txt' => Uint8List(0),
            _ => throw const FileSystemException('gone'),
          };
        },
      );
      expect(read, hasLength(4));
      expect(request.text, '报价\nhttps://example.com/a');
      expect(request.attachments.map((a) => (a.name, a.isImage)), [('a.png', true), ('报价单.pdf', false)]);
      expect(request.problems, ['「movie.mp4」太大，未添加', '没能读取「gone.txt」', '「empty.txt」是空文件']);
      expect(request.voice, isFalse);
    });

    test('deletes the cached copies once read', () async {
      final dir = Directory.systemTemp.createTempSync('share');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final slot = Directory('${dir.path}/slot')..createSync();
      final file = File('${slot.path}/a.png')..writeAsBytesSync(_png);
      final request = await ComposeRequest.fromShare(
        IncomingShare(
          files: [SharedFile(path: file.path, name: 'a.png')],
        ),
      );
      expect(request.attachments.single.bytes, _png);
      expect(file.existsSync(), isFalse);
      expect(slot.existsSync(), isFalse);
    });

    test('says what each skip means', () {
      expect(skippedText(const SkippedShare(ShareSkipReason.tooMany)), '每条消息最多 9 个附件');
      expect(skippedText(const SkippedShare(ShareSkipReason.tooLarge)), '有文件太大，未添加');
      expect(skippedText(const SkippedShare(ShareSkipReason.unreadable, 'a.doc')), '没能读取「a.doc」');
      expect(skippedText(const SkippedShare(ShareSkipReason.unreadable)), '有文件没能读取');
    });
  });

  test('fromFile attaches an opened file', () async {
    final ok = await ComposeRequest.fromFile('/c/links/x/notes.md', read: (_) async => Uint8List.fromList([35, 10]));
    expect(ok.attachments.single.name, 'notes.md');
    final failed = await ComposeRequest.fromFile(
      '/c/links/x/a.bin',
      read: (_) async => throw const FileSystemException('x'),
    );
    expect(failed.attachments, isEmpty);
    expect(failed.problems, ['没能读取「a.bin」']);
  });

  group('mergeIntoDraft', () {
    test('adds the shared text under the draft and attachments after its own', () {
      final own = _image('mine.png');
      final merged = mergeIntoDraft(
        text: '先写了一句  ',
        attachments: [own],
        request: ComposeRequest(text: '分享来的', attachments: [_file('a.txt')]),
        filesAllowed: true,
      );
      expect(merged.text, '先写了一句\n\n分享来的');
      expect(merged.attachments.map((a) => a.name), ['mine.png', 'a.txt']);
      expect(merged.problem, isNull);
    });

    test('an empty draft takes the text as it is; no text keeps the draft', () {
      expect(
        mergeIntoDraft(
          text: '',
          attachments: const [],
          request: const ComposeRequest(text: '  只有这句 '),
          filesAllowed: true,
        ).text,
        '只有这句',
      );
      expect(
        mergeIntoDraft(
          text: '草稿',
          attachments: const [],
          request: ComposeRequest(attachments: [_image('a.png')]),
          filesAllowed: true,
        ).text,
        '草稿',
      );
    });

    test('stops at the attachment limit and says so', () {
      final merged = mergeIntoDraft(
        text: '',
        attachments: [for (var i = 0; i < 7; i++) _image('$i.png')],
        request: ComposeRequest(attachments: [_image('a.png'), _image('b.png'), _image('c.png')]),
        filesAllowed: true,
      );
      expect(merged.attachments, hasLength(maxAttachments));
      expect(merged.attachments.last.name, 'b.png');
      expect(merged.problem, '每条消息最多 9 个附件');
    });

    test('a host that takes only images keeps the images', () {
      final merged = mergeIntoDraft(
        text: '',
        attachments: const [],
        request: ComposeRequest(attachments: [_file('a.pdf'), _image('b.png')]),
        filesAllowed: false,
      );
      expect(merged.attachments.map((a) => a.name), ['b.png']);
      expect(merged.problem, '当前主机只能发送图片');
    });

    test('the request’s own problems come first', () {
      final merged = mergeIntoDraft(
        text: '',
        attachments: const [],
        request: ComposeRequest(attachments: [_file('a.pdf')], problems: const ['「x」太大，未添加']),
        filesAllowed: false,
      );
      expect(merged.problem, '「x」太大，未添加');
    });

    test('a very long text becomes a text file, or is cut where files cannot go', () {
      final long = '字' * (maxComposerShareChars + 10);
      final asFile = mergeIntoDraft(
        text: '总结一下',
        attachments: const [],
        request: ComposeRequest(text: long, attachments: [_image('a.png')]),
        filesAllowed: true,
      );
      expect(asFile.text, '总结一下');
      expect(asFile.attachments.map((a) => a.name), [sharedTextFileName, 'a.png']);
      expect(utf8.decode(asFile.attachments.first.bytes), long);
      expect(asFile.problem, isNull);

      final cut = mergeIntoDraft(
        text: '',
        attachments: const [],
        request: ComposeRequest(text: long),
        filesAllowed: false,
      );
      expect(cut.text.length, maxComposerShareChars);
      expect(cut.problem, '文字太长，只保留了前 $maxComposerShareChars 字');
    });

    test('never cuts an emoji in half', () {
      final long = '${'a' * (maxComposerShareChars - 1)}😀tail';
      final cut = mergeIntoDraft(
        text: '',
        attachments: const [],
        request: ComposeRequest(text: long),
        filesAllowed: false,
      );
      expect(cut.text, 'a' * (maxComposerShareChars - 1));
    });
  });

  test('canStageFiles asks the connection, else the host kind', () {
    final connection = HostConnection(hostId: '', 
      client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))),
      label: '本机',
      isLocal: true,
    );
    expect(canStageFiles(connection, HostRef.none), isTrue);
    expect(canStageFiles(null, HostRef.none), isTrue);
    expect(canStageFiles(null, const HostRef.portal('a')), isTrue);
    expect(canStageFiles(null, const HostRef.portal('r')), isFalse);
  });

  group('inbox', () {
    test('first in, first out', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final inbox = container.read(composeInboxProvider.notifier);
      inbox
        ..push(const ComposeRequest(text: '一'))
        ..push(const ComposeRequest.newChat(voice: true));
      expect(inbox.take()?.text, '一');
      expect(inbox.take()?.voice, isTrue);
      expect(inbox.take(), isNull);
    });

    test('waits for the saved drafts before handing anything out', () {
      final drafts = _Drafts(const DraftState());
      final container = ProviderContainer(overrides: [draftStoreProvider.overrideWith(() => drafts)]);
      addTearDown(container.dispose);
      final seen = <String?>[];
      container.listen(readyComposeProvider, (_, next) => seen.add(next?.text), fireImmediately: true);
      container.read(composeInboxProvider.notifier).push(const ComposeRequest(text: '分享'));
      expect(container.read(readyComposeProvider), isNull);
      drafts.load();
      expect(container.read(readyComposeProvider)?.text, '分享');
      container.read(composeInboxProvider.notifier).take();
      expect(container.read(readyComposeProvider), isNull);
      expect(seen, [null, '分享', null]);
    });
  });
}
