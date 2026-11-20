import 'dart:async';

import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/files_harness.dart';

String _lines(String prefix) => [for (var i = 1; i <= 1200; i++) '$prefix line $i'].join('\n');

class _Page {
  _Page(this.snapshot);
  final Future<DshWorkspaceText> snapshot;
  final result = Completer<DshWorkspaceText>();

  Future<void> succeed() async => result.complete(await snapshot);
  void fail() => result.completeError(const DshRemoteException('offline', 'page unavailable', {}));
}

class _Workspace extends MemoryWorkspace {
  _Workspace() : super(files: {'live.log': _lines('old')});

  final pages = <_Page>[];
  bool failNextReload = false;
  bool holdNextReload = false;
  _Page? reload;

  @override
  Future<DshWorkspaceText> read(String path, {int offset = 1, int limit = previewPageLines}) {
    if (offset == 1) {
      if (failNextReload) {
        failNextReload = false;
        return Future.error(const DshRemoteException('offline', 'reload unavailable', {}));
      }
      if (holdNextReload) {
        holdNextReload = false;
        final pending = _Page(super.read(path, offset: offset, limit: limit));
        reload = pending;
        return pending.result.future;
      }
      return super.read(path, offset: offset, limit: limit);
    }
    final page = _Page(super.read(path, offset: offset, limit: limit));
    pages.add(page);
    return page.result.future;
  }
}

Future<_Workspace> _open(WidgetTester tester) async {
  usePhoneView(tester);
  final workspace = _Workspace();
  await tester.pumpWidget(filesApp(FilePreviewPage(sessionId: 's1', path: '${workspace.root}/live.log'), workspace));
  await pumpFrames(tester, 8);
  expect(workspace.watching('live.log'), 1);
  expect(find.textContaining('old line 500', findRichText: true), findsWidgets);
  return workspace;
}

Future<void> _nearEnd(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -30000));
  await pumpFrames(tester, 4);
}

Future<void> _change(WidgetTester tester, _Workspace workspace) async {
  workspace.write('live.log', _lines('new'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 401));
  await pumpFrames(tester, 4);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a file change releases paging after the obsolete page succeeds', (tester) async {
    final workspace = await _open(tester);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));

    await _change(tester, workspace);
    expect(find.textContaining('new line 500', findRichText: true), findsWidgets);
    await workspace.pages.single.succeed();
    await tester.pump();
    expect(find.textContaining('old line 501', findRichText: true), findsNothing);

    await _nearEnd(tester);
    expect(workspace.pages, hasLength(2));
    await workspace.pages.last.succeed();
    await tester.pump();
    expect(find.textContaining('new line 1000', findRichText: true), findsWidgets);
  });

  testWidgets('an obsolete page failure does not unlock the current paging request', (tester) async {
    final workspace = await _open(tester);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));
    final obsolete = workspace.pages.single;

    await _change(tester, workspace);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(2));
    final current = workspace.pages.last;
    obsolete.fail();
    await tester.pump();
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(2), reason: 'the current page is still pending');
    await current.succeed();
    await tester.pump();
    expect(find.textContaining('new line 1000', findRichText: true), findsWidgets);
  });

  testWidgets('a failed file refresh keeps text and permits paging to recover', (tester) async {
    final workspace = await _open(tester);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));
    workspace.failNextReload = true;

    await _change(tester, workspace);
    expect(find.textContaining('old line 500', findRichText: true), findsWidgets);
    await workspace.pages.single.succeed();
    await tester.pump();
    expect(find.textContaining('old line 501', findRichText: true), findsNothing);

    await _nearEnd(tester);
    expect(workspace.pages, hasLength(2));
    await workspace.pages.last.succeed();
    await pumpFrames(tester, 4);
    // The page's newer version reloads from the top instead of mixing versions.
    expect(find.textContaining('new line 500', findRichText: true), findsWidgets);
    expect(find.textContaining('old line 500', findRichText: true), findsNothing);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(3));
    await workspace.pages.last.succeed();
    await tester.pump();
    expect(find.textContaining('new line 1000', findRichText: true), findsWidgets);
  });

  testWidgets('a current page failure remains retryable', (tester) async {
    final workspace = await _open(tester);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));
    workspace.pages.single.fail();
    await tester.pump();
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(2));
    await workspace.pages.last.succeed();
    await tester.pump();
    expect(find.textContaining('old line 1000', findRichText: true), findsWidgets);
  });

  testWidgets('a reload retains the busy state of paging started after it', (tester) async {
    final workspace = await _open(tester);
    workspace.holdNextReload = true;
    await _change(tester, workspace);
    expect(workspace.reload, isNotNull);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));
    final current = workspace.pages.single;

    await workspace.reload!.succeed();
    await tester.pump();
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1), reason: 'the new page is still pending');
    await current.succeed();
    await tester.pump();
    expect(find.textContaining('new line 1000', findRichText: true), findsWidgets);
  });

  testWidgets('a page response after leaving the preview has no UI effect', (tester) async {
    final workspace = await _open(tester);
    await _nearEnd(tester);
    expect(workspace.pages, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await workspace.pages.single.succeed();
    await tester.pump();
    expect(workspace.watching('live.log'), 0);
    expect(tester.takeException(), isNull);
  });
}
