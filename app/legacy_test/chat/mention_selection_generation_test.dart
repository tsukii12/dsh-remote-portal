import 'dart:async';

import 'package:dsh_app/state/mention_state.dart';
import 'package:dsh_app/ui/chat/mention/mention_controller.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _oldFiles = [
  FileReferenceCandidate(path: 'old.txt', isDirectory: false),
  FileReferenceCandidate(path: 'old-dir', isDirectory: true),
];
const _newFiles = [
  FileReferenceCandidate(path: 'new.txt', isDirectory: false),
  FileReferenceCandidate(path: 'new-dir', isDirectory: true),
];

class _Source implements MentionSource {
  final pending = Completer<List<FileReferenceCandidate>>();
  final queries = <String>[];

  @override
  Future<List<FileReferenceCandidate>> files(String sessionId, String query) {
    queries.add(query);
    return query == 'new' ? pending.future : Future.value(_oldFiles);
  }

  @override
  Future<List<SessionReferenceCandidate>> sessions(String sessionId, String query) async => const [];

  @override
  Future<List<SessionSummary>> allSessions() async => const [];
}

class _Fixture {
  _Fixture() {
    picker = MentionPickerController(
      input: input,
      source: () => source,
      sessionId: () => 'main',
      localSessions: () async => const [],
      recents: recents,
    );
  }

  final input = MentionTextController();
  final source = _Source();
  final recents = MentionRecents(persist: false);
  final focus = FocusNode();
  late final MentionPickerController picker;

  void type(String text) {
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> open(WidgetTester tester) async {
    type('@old');
    await tester.pump();
    expect(picker.items.map((item) => item.path), ['old.txt', 'old-dir']);
    expect(picker.highlighted, 0);
    expect(picker.loading, isFalse);
  }

  KeyEventResult key(LogicalKeyboardKey key) => picker.handleKey(
    focus,
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.enter, logicalKey: key, timeStamp: Duration.zero),
  );

  void dispose() {
    picker.dispose();
    focus.dispose();
    input.dispose();
  }
}

void main() {
  for (final requestStarted in [false, true]) {
    final phase = requestStarted ? 'while the request is pending' : 'before the debounce fires';
    for (final action in ['send', 'enter', 'tab', 'pick', 'drill']) {
      testWidgets('$action cannot select the previous query $phase', (tester) async {
        final f = _Fixture();
        addTearDown(f.dispose);
        await f.open(tester);
        final oldFile = f.picker.items.first;
        final oldFolder = f.picker.items.last;
        f.type('@new');
        if (requestStarted) await tester.pump(const Duration(milliseconds: 120));
        expect(f.source.queries, requestStarted ? ['old', 'new'] : ['old']);
        expect(f.picker.loading, isTrue);

        switch (action) {
          case 'send':
            expect(f.picker.pickHighlighted(), isFalse);
          case 'enter':
            expect(f.key(LogicalKeyboardKey.enter), KeyEventResult.ignored);
          case 'tab':
            expect(f.key(LogicalKeyboardKey.tab), KeyEventResult.ignored);
          case 'pick':
            f.picker.pick(oldFile);
          case 'drill':
            f.picker.drill(oldFolder);
        }
        expect(f.input.text, '@new');
        expect(f.input.tokens, isEmpty);
        expect(f.recents.entries, isEmpty);
        expect(f.picker.sections, isEmpty);
        expect(f.picker.highlighted, -1);

        f.source.pending.complete(_newFiles);
        if (!requestStarted) await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        expect(f.picker.pickHighlighted(), isTrue);
        expect(f.input.text, '@new.txt ');
        expect(f.recents.entries.single.key, 'f:new.txt');
      });
    }
  }

  testWidgets('a same-key row from the previous batch has no selection authority', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.open(tester);
    final oldFile = f.picker.items.first;
    final oldFolder = f.picker.items.last;
    f.type('@new');
    await tester.pump(const Duration(milliseconds: 120));
    f.source.pending.complete(_oldFiles);
    await tester.pump();
    expect(f.picker.items.first.key, oldFile.key);
    expect(identical(f.picker.items.first, oldFile), isFalse);
    f.picker.pick(oldFile);
    f.picker.drill(oldFolder);
    expect(f.input.text, '@new');
    expect(f.recents.entries, isEmpty);
    f.picker.pick(f.picker.items.first);
    expect(f.input.text, '@old.txt ');
  });

  testWidgets('dismissed rows cannot be picked or opened by a retained callback', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.open(tester);
    final oldFile = f.picker.items.first;
    final oldFolder = f.picker.items.last;
    expect(f.key(LogicalKeyboardKey.escape), KeyEventResult.handled);
    f.picker.pick(oldFile);
    f.picker.drill(oldFolder);
    expect(f.input.text, '@old');
    expect(f.recents.entries, isEmpty);
    expect(f.picker.pickHighlighted(), isFalse);
    f.type('@new');
    await tester.pump(const Duration(milliseconds: 120));
    expect(f.picker.isOpen, isFalse);
    expect(f.source.queries, ['old']);
  });

  testWidgets('unchanged query keeps its current rows and a folder can still be opened', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.open(tester);
    final folder = f.picker.items.last;
    f.input.selection = const TextSelection.collapsed(offset: 4, affinity: TextAffinity.upstream);
    expect(identical(f.picker.items.last, folder), isTrue);
    expect(f.picker.loading, isFalse);
    f.picker.drill(folder);
    expect(f.input.text, '@old-dir/');
    expect(f.recents.entries, isEmpty);
    await tester.pump(const Duration(milliseconds: 120));
  });

  testWidgets('a bare mention has no default send selection but permits an explicit current row', (tester) async {
    final f = _Fixture();
    addTearDown(f.dispose);
    f.type('@');
    await tester.pump();
    expect(f.picker.pickHighlighted(), isFalse);
    f.picker.pick(f.picker.items.first);
    expect(f.input.text, '@old.txt ');
  });
}
