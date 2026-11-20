import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share/share_panel_pages.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

const _title = 'same conversation';
const _channel = MethodChannel('test/conversation-save-source');

class _Save {
  _Save(this.path, this.name, this.mime);

  final String path;
  final String name;
  final String mime;
  String? content;
}

class _NativeSaves {
  // Constructed in runAsync: these barriers belong to the real file-I/O zone.
  final entered = List.generate(2, (_) => Completer<_Save>());
  final release = List.generate(2, (_) => Completer<void>());
  final read = List.generate(2, (_) => Completer<void>());
  var calls = 0;
  var refuse = false;

  Future<Object?> handle(MethodCall call) async {
    expect(call.method, 'saveToDownloads');
    final args = call.arguments as Map;
    final save = _Save(args['path'] as String, args['name'] as String, args['mime'] as String);
    final index = calls++;
    entered[index].complete(save);
    await release[index].future;
    save.content = await File(save.path).readAsString();
    read[index].complete();
    if (refuse) throw PlatformException(code: 'permission', message: 'controlled native save refusal');
    return 'Download/DSH-Go/${save.name}';
  }

  void unblock() {
    for (final gate in release) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

ReplaySource _replay(String text) {
  final at = DateTime.utc(2026, 10, 24);
  return ReplaySource(
    share: ConversationShare(title: _title, start: at, entries: const []),
    state: ChatState(
      title: _title,
      loading: false,
      items: [
        UserChatItem(seq: 1, time: at, text: 'Please export', images: const [], files: const []),
        AssistantChatItem(id: 'a2', seq: 2, time: at, text: text, reasoning: ''),
      ],
    ),
  );
}

Future<void> _settled(WidgetTester tester, List<SharePanelModel> models) async {
  // A disposed panel no longer notifies listeners. Wait for its public work
  // state as well, yielding event turns for the real channel/FS continuations.
  // Neither a fixed delay nor a fixed number of turns stands in for completion.
  await tester.runAsync(() async {
    while (models.any((model) => model.work != null)) {
      await Future<void>(() {});
    }
  });
  await tester.pump();
}

Future<SharePanelModel> _open(WidgetTester tester, ConversationFormat format) async {
  await tester.tap(find.byKey(const ValueKey('open-share')));
  await tester.pumpAndSettle();
  final model = SharePanelScope.of(tester.element(find.byType(SharePanelHome)));
  await tester.runAsync(model.prepare);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('share-to-file')));
  await tester.pumpAndSettle();
  model.format = format;
  await tester.pump();
  expect(find.byType(ShareFilePage), findsOneWidget);
  return model;
}

Future<void> _close(WidgetTester tester) async {
  // The production drag handle closes the dismissible sheet even during save.
  await tester.tap(find.byType(SheetDragHandle));
  await tester.pumpAndSettle();
  expect(find.byType(SharePanel), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final format in ConversationFormat.values) {
    testWidgets('reopened ${format.name} save keeps the first native worker source', (tester) async {
      final cache = Directory.systemTemp.createTempSync('conversation-save-');
      final native = (await tester.runAsync(() async => _NativeSaves()))!;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_channel, native.handle);
      addTearDown(() {
        native.unblock();
        messenger.setMockMethodCallHandler(_channel, null);
        cache.deleteSync(recursive: true);
      });
      final out = ConversationOut(files: const FilesChannel(_channel), cacheRoot: () async => cache);
      var source = _replay('FIRST-CONTENT');
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-share'),
                onPressed: () => showSharePanel(context, ConversationSubject(replay: source)),
                child: const Text('open'),
              ),
            ),
          ),
          overrides: [
            settingsProvider.overrideWith(TestSettings.new),
            conversationOutProvider.overrideWithValue(out),
            conversationLinkMakerProvider.overrideWithValue(null),
          ],
        ),
      );

      final firstModel = await _open(tester, format);
      final expectedFirst = firstModel.built!.of(format).text;
      final first = (await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-file-save')));
        return native.entered[0].future;
      }))!;
      expect(firstModel.work, ShareWork.saving);
      await _close(tester);
      source = _replay('SECOND-CONTENT');
      final secondModel = await _open(tester, format);
      final expectedSecond = secondModel.built!.of(format).text;
      expect(secondModel, isNot(same(firstModel)));
      final second = (await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('share-file-save')));
        return native.entered[1].future;
      }))!;

      await tester.runAsync(() async {
        native.release[1].complete();
        await native.read[1].future;
        native.release[0].complete();
        await native.read[0].future;
      });
      await _settled(tester, [firstModel, secondModel]);
      expect(firstModel.work, isNull, reason: 'the dismissed save also consumed its native reply');
      expect(secondModel.work, isNull);
      expect(secondModel.fileSaved, isTrue);
      expect(first.name, '$_title.${format.extension}');
      expect(second.name, first.name);
      expect([first.mime, second.mime], [format.mime, format.mime]);
      expect(expectedFirst, isNot(expectedSecond));
      debugPrint(
        '${format.name}: firstOwn=${first.content == expectedFirst}, '
        'firstReplaced=${first.content == expectedSecond}, secondOwn=${second.content == expectedSecond}',
      );
      expect(second.content == expectedSecond, isTrue);
      expect(first.content == expectedFirst, isTrue, reason: 'the first worker must read its requested snapshot');
      if (format == ConversationFormat.file) {
        final decoded = decodeConversationFile(first.content!).share;
        expect(decoded.entries.whereType<ReplyEntry>().single.text, 'FIRST-CONTENT');
      }
      expect(first.path, isNot(second.path));
      expect(File(first.path).existsSync(), isFalse);
      expect(File(second.path).existsSync(), isFalse);
      await _close(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('native save refusal stays visible and the same panel can retry', (tester) async {
    final cache = Directory.systemTemp.createTempSync('conversation-save-refusal-');
    final native = (await tester.runAsync(() async => _NativeSaves()))!..refuse = true;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, native.handle);
    addTearDown(() {
      native.unblock();
      messenger.setMockMethodCallHandler(_channel, null);
      cache.deleteSync(recursive: true);
    });
    final out = ConversationOut(files: const FilesChannel(_channel), cacheRoot: () async => cache);
    final previous = (await tester.runAsync(() => out.write('previous.md', 'previous content')))!;
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-share'),
              onPressed: () => showSharePanel(context, ConversationSubject(replay: _replay('RETRY-CONTENT'))),
              child: const Text('open'),
            ),
          ),
        ),
        overrides: [
          settingsProvider.overrideWith(TestSettings.new),
          conversationOutProvider.overrideWithValue(out),
          conversationLinkMakerProvider.overrideWithValue(null),
        ],
      ),
    );
    final model = await _open(tester, ConversationFormat.file);
    await tester.runAsync(() async {
      native.release[0].complete();
      await tester.tap(find.byKey(const ValueKey('share-file-save')));
      await native.read[0].future;
    });
    await _settled(tester, [model]);
    expect(model.error, appL10n.viewShareNoPermission);
    expect(model.fileSaved, isFalse);
    expect(find.text(appL10n.viewShareNoPermission), findsOneWidget);
    native.refuse = false;
    await tester.runAsync(() async {
      native.release[1].complete();
      await tester.tap(find.byKey(const ValueKey('share-file-save')));
      await native.read[1].future;
    });
    await _settled(tester, [model]);
    expect(model.error, isNull);
    expect(model.fileSaved, isTrue);
    expect(previous.readAsStringSync(), 'previous content');
    expect(native.calls, 2);
    await _close(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
