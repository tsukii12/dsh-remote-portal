import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _mib = 1024 * 1024;
const _png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

Iterable<Uint8List> _megabytes(int count) sync* {
  final chunk = Uint8List(_mib);
  for (var i = 0; i < count; i++) {
    yield chunk;
  }
}

final class _File extends PlatformFile {
  _File(this.name, this.chunks, {this.reportedLength, this.failure});

  @override
  final String name;
  final Iterable<Uint8List> chunks;
  final int? reportedLength;
  final Exception? failure;
  int streams = 0;
  int wholeReads = 0;
  int emitted = 0;
  int consumed = 0;
  bool closed = false;

  @override
  Uri get uri => Uri.parse('memory:$name');
  @override
  Never get xFile => throw UnsupportedError('Use the picker byte stream');
  @override
  int? lengthSync() => reportedLength;
  @override
  Future<int?> length() => throw StateError('Do not read a file just to learn its length');
  @override
  Future<Uint8List> readAsBytes() async {
    wholeReads++;
    throw StateError('Whole-file reads bypass the budget');
  }

  @override
  Stream<Uint8List> readAsByteStream() async* {
    streams++;
    try {
      for (final chunk in chunks) {
        emitted++;
        consumed += chunk.length;
        yield chunk;
      }
      if (failure case final error?) throw error;
    } finally {
      closed = true;
    }
  }
}

class _Picker extends FilePickerPlatform {
  List<PlatformFile> selected = [];
  Exception? failure;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (failure case final error?) throw error;
    return selected;
  }
}

_File _small(String name) => _File(name, [
  Uint8List.fromList([1, 2, 3]),
], reportedLength: 3);

Future<void> _screen(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        for (final override in harness.overrides)
          if (override.origin != attachmentPickerProvider) override,
        attachmentPickerProvider.overrideWithValue(const DeviceAttachmentPicker()),
      ],
    ),
  );
  await pumpFrames(tester);
}

Future<void> _choose(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('添加图片或文件'));
  await pumpFrames(tester);
  await tester.tap(find.text('文件'));
  await pumpFrames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = DeviceAttachmentPicker();
  late FilePickerPlatform original;
  late _Picker picker;

  setUp(() {
    original = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() => FilePickerPlatform.instance = original);

  test('failed file read keeps earlier and later valid selections', () async {
    final unreadable = _File('unreadable.txt', [
      Uint8List.fromList([1, 2]),
    ], failure: const FileSystemException('read interrupted'));
    picker.selected = [_small('before.txt'), unreadable, _small('after.txt')];

    final result = await device.pickFiles(limit: 2);

    expect(result.attachments.map((a) => a.name), ['before.txt', 'after.txt']);
    expect(result.attachments.map((a) => a.bytes.toList()), [
      [1, 2, 3],
      [1, 2, 3],
    ]);
    expect(result.problem, appL10n.stateShareReadFailed(unreadable.name));
    expect(unreadable.consumed, 2);
    expect(unreadable.closed, isTrue);
    expect(unreadable.wholeReads, 0);
  });

  test('failed partial read leaves its message budget for a later file', () async {
    final unreadable = _File('unreadable.txt', [
      Uint8List.fromList([1, 2]),
    ], failure: const FileSystemException('read interrupted'));
    picker.selected = [unreadable, _small('fits.txt')];

    final result = await device.pickFiles(limit: 1, heldBytes: maxMessageBytes - 3);

    expect(result.attachments.single.name, 'fits.txt');
    expect(result.attachments.single.size, 3);
    expect(result.problem, appL10n.stateShareReadFailed(unreadable.name));
    expect(unreadable.closed, isTrue);
  });

  test('first rejection remains visible after a later file read failure', () async {
    final large = _File('large.zip', const [], reportedLength: maxFileBytes + 1);
    final unreadable = _File('unreadable.txt', const [], failure: const FileSystemException('cannot open'));
    picker.selected = [large, unreadable, _small('good.txt')];

    final result = await device.pickFiles();

    expect(result.attachments.single.name, 'good.txt');
    expect(result.problem, appL10n.stateAttachmentFileLimit(large.name));
    expect(large.streams, 0);
    expect(unreadable.closed, isTrue);
  });

  test('all failed file reads still return the first named failure', () async {
    final first = _File('first.txt', const [], failure: const FileSystemException('cannot open'));
    final second = _File('second.txt', const [], failure: const FileSystemException('cannot open'));
    picker.selected = [first, second];

    final result = await device.pickFiles();

    expect(result.attachments, isEmpty);
    expect(result.problem, appL10n.stateShareReadFailed(first.name));
    expect(first.closed, isTrue);
    expect(second.closed, isTrue);
  });

  test('picker permission failure still propagates before any file reads', () async {
    final denied = PlatformException(code: 'permission_denied', message: 'selection was denied');
    final selected = _small('not-read.txt');
    picker
      ..selected = [selected]
      ..failure = denied;

    await expectLater(device.pickFiles(), throwsA(same(denied)));

    expect(selected.streams, 0);
  });

  testWidgets('composer keeps valid selections and names a failed file read', (tester) async {
    final unreadable = _File('unreadable.txt', [
      Uint8List.fromList([1, 2]),
    ], failure: const FileSystemException('read interrupted'));
    picker.selected = [_small('before.txt'), unreadable, _small('after.txt')];
    await _screen(tester, ChatHarness(session: 's1'));

    await _choose(tester);

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final attachments = container.read(draftStoreProvider).drafts['s1']?.attachments ?? const [];
    expect(attachments.map((a) => a.name), ['before.txt', 'after.txt']);
    expect(find.text(appL10n.stateShareReadFailed(unreadable.name)), findsOneWidget);
    expect(unreadable.closed, isTrue);
  });

  test('known oversize is rejected before opening, while later valid files survive', () async {
    // 500 MiB is metadata only. The fixture would yield at most 1 MiB.
    final large = _File('video.mp4', _megabytes(1), reportedLength: 500 * _mib);
    final good = _small('notes.txt');
    picker.selected = [large, good];
    final result = await device.pickFiles();
    expect(result.attachments.map((a) => a.name), ['notes.txt']);
    expect(result.problem, appL10n.stateAttachmentFileLimit(large.name));
    expect(large.streams, 0);
    expect(large.wholeReads, 0);
  });

  for (final reported in <int?>[null, 0, 1, maxFileBytes]) {
    test('unknown or stale size $reported still stops at the first oversized chunk', () async {
      final file = _File('export.zip', _megabytes(maxFileBytes ~/ _mib + 1), reportedLength: reported);
      picker.selected = [file];
      final result = await device.pickFiles();
      expect(result.attachments, isEmpty);
      expect(result.problem, appL10n.stateAttachmentFileLimit(file.name));
      expect(file.consumed, maxFileBytes + _mib);
      expect(file.closed, isTrue);
      expect(file.wholeReads, 0);
    });
  }

  test('one oversized upstream chunk is rejected and the tail is never requested', () async {
    final file = _File('single.bin', [Uint8List(maxFileBytes + 1), Uint8List(1)]);
    picker.selected = [file];
    final result = await device.pickFiles();
    expect(result.attachments, isEmpty);
    expect(file.emitted, 1);
    expect(file.closed, isTrue);
  });

  test('a multi-file pick stops at the message byte budget', () async {
    // 150 MiB each with known sizes: two fit (300 MiB), the third would pass 400 MiB.
    final files = [
      for (var i = 0; i < 3; i++) _File('part$i.bin', _megabytes(150), reportedLength: 150 * _mib),
    ];
    picker.selected = files;
    final result = await device.pickFiles();
    expect(result.attachments.map((a) => a.name), ['part0.bin', 'part1.bin']);
    expect(result.problem, appL10n.stateAttachmentTotalLimit);
    expect(files[2].streams, 0);
  });

  test('bytes already in the tray count before another file is opened', () async {
    final file = _File('tail.bin', _megabytes(150), reportedLength: 150 * _mib);
    picker.selected = [file];
    final result = await device.pickFiles(heldBytes: maxMessageBytes - 100 * _mib);
    expect(result.attachments, isEmpty);
    expect(result.problem, appL10n.stateAttachmentTotalLimit);
    expect(file.streams, 0);
  });

  test('a streamed aggregate overflow reports the total-size limit', () async {
    // Unknown length, so the guard fires while streaming, not on metadata.
    final file = _File('extra.bin', _megabytes(20));
    picker.selected = [file];
    final result = await device.pickFiles(heldBytes: maxMessageBytes - 10 * _mib);
    expect(result.attachments, isEmpty);
    expect(result.problem, appL10n.stateAttachmentTotalLimit);
    expect(file.closed, isTrue);
  });

  test('split image signature applies 20 MiB before retaining the offending chunk', () async {
    final file = _File('misleading.bin', [
      Uint8List.fromList(_png.take(3).toList()),
      Uint8List.fromList(_png.skip(3).toList()),
      ..._megabytes(21),
    ]);
    picker.selected = [file];
    final result = await device.pickFiles();
    expect(result.attachments, isEmpty);
    expect(result.problem, appL10n.stateAttachmentImageLimit(file.name));
    expect(file.consumed, maxImageBytes + _png.length);
    expect(file.closed, isTrue);
  });

  test('known image size over 20 MiB is refused as soon as its true prefix is known', () async {
    final file = _File('no-extension', [
      Uint8List.fromList(_png.take(3).toList()),
      Uint8List.fromList(_png.skip(3).toList()),
      Uint8List(_mib),
    ], reportedLength: 21 * _mib);
    picker.selected = [file];
    final result = await device.pickFiles();
    expect(result.problem, appL10n.stateAttachmentImageLimit(file.name));
    expect(file.consumed, _png.length);
    expect(file.closed, isTrue);
  });

  test('normal file named png retains the 200 MiB allowance and accepts its exact boundary', () async {
    final file = _File('not-an-image.png', _megabytes(maxFileBytes ~/ _mib), reportedLength: maxFileBytes);
    picker.selected = [file];
    final result = await device.pickFiles();
    expect(result.problem, isNull);
    expect(result.attachments.single.size, maxFileBytes);
    expect(result.attachments.single.isImage, isFalse);
  });

  test('inline image at exactly 20 MiB remains accepted', () async {
    final file = _File('image.data', [Uint8List.fromList(_png), Uint8List(maxImageBytes - _png.length)]);
    picker.selected = [file];
    final result = await device.pickFiles();
    expect(result.problem, isNull);
    expect(result.attachments.single.size, maxImageBytes);
    expect(result.attachments.single.mediaType, 'image/png');
  });

  test('bad files do not consume capacity and the first issue survives later overflow', () async {
    final large = _File('large.zip', const [], reportedLength: maxFileBytes + 1);
    final empty = _File('empty.txt', const []);
    final extra = _small('not-read.txt');
    picker.selected = [large, empty, _small('a.txt'), _small('b.txt'), extra];
    final result = await device.pickFiles(limit: 2);
    expect(result.attachments.map((a) => a.name), ['a.txt', 'b.txt']);
    expect(result.problem, appL10n.stateAttachmentFileLimit(large.name));
    expect(extra.streams, 0);
  });

  test('overflow after remaining capacity reports the existing per-message limit', () async {
    final extra = _small('not-read.txt');
    picker.selected = [_small('a.txt'), extra];
    final result = await device.pickFiles(limit: 1);
    expect(result.attachments.single.name, 'a.txt');
    expect(result.problem, appL10n.chatAttachmentLimit(maxAttachments));
    expect(extra.streams, 0);
  });

  test('empty picks keep their feedback, while cancellation stays silent', () async {
    final empty = _File('empty.txt', const []);
    picker.selected = [empty, _small('a.txt')];
    final result = await device.pickFiles();
    expect(result.attachments.single.name, 'a.txt');
    expect(result.problem, appL10n.stateAttachmentEmpty(empty.name));
    picker.selected = [];
    final cancelled = await device.pickFiles();
    expect(cancelled.attachments, isEmpty);
    expect(cancelled.problem, isNull);
  });

  testWidgets('composer keeps a good pick and shows the first pre-read rejection', (tester) async {
    final large = _File('video.mp4', const [], reportedLength: 500 * _mib);
    picker.selected = [large, _small('small.txt')];
    await _screen(tester, ChatHarness(session: 's1'));
    await _choose(tester);
    expect(find.text('small.txt'), findsOneWidget);
    expect(find.text(appL10n.stateAttachmentFileLimit(large.name)), findsOneWidget);
    expect(large.streams, 0);
  });

  testWidgets('composer shows rejection even when no attachments were accepted', (tester) async {
    final large = _File('video.mp4', const [], reportedLength: 500 * _mib);
    picker.selected = [large];
    await _screen(tester, ChatHarness(session: 's1'));
    await _choose(tester);
    expect(find.text(appL10n.stateAttachmentFileLimit(large.name)), findsOneWidget);
  });

  testWidgets('composer passes its remaining capacity before the next file is read', (tester) async {
    picker.selected = [for (var i = 0; i < 8; i++) _small('first-$i.txt')];
    await _screen(tester, ChatHarness(session: 's1'));
    await _choose(tester);
    final extra = _small('not-read.txt');
    picker.selected = [_small('last.txt'), extra];
    await _choose(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final attachments = container.read(draftStoreProvider).drafts['s1']!.attachments;
    expect(attachments.length, maxAttachments);
    expect(attachments.last.name, 'last.txt');
    expect(find.text(appL10n.chatAttachmentLimit(maxAttachments)), findsOneWidget);
    expect(extra.streams, 0);
  });
}
