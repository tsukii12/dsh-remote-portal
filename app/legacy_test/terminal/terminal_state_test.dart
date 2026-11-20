// The terminal workspace against a scripted Host: restore, create, input,
// resize, exit, drops and reconnects, close, rename, shell memory and the
// font size.

import 'dart:async';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _session = 's1';

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeTerminalBackend backend;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TerminalWorkspace.viewSizeWait = Duration.zero;
    TerminalWorkspace.resizeSettle = Duration.zero;
  });
  tearDown(() {
    TerminalWorkspace.viewSizeWait = const Duration(milliseconds: 400);
    TerminalWorkspace.resizeSettle = const Duration(milliseconds: 150);
  });

  Future<TerminalWorkspace> open(FakeTerminalBackend fake) async {
    backend = fake;
    container = ProviderContainer(overrides: terminalOverrides(fake));
    addTearDown(container.dispose);
    container.listen(terminalWorkspaceProvider(_session), (_, _) {});
    await _settle();
    return container.read(terminalWorkspaceProvider(_session).notifier);
  }

  TerminalWorkspaceState read() => container.read(terminalWorkspaceProvider(_session));

  test('an empty conversation gets one fresh terminal, live and writable', () async {
    await open(FakeTerminalBackend());
    final state = read();
    expect(state.loading, isFalse);
    expect(state.tabs, hasLength(1));
    final tab = state.selected!;
    expect(tab.phase, TerminalPhase.live);
    expect(tab.writable, isTrue);
    expect(tab.title, 'bash');
    expect(backend.created.single['id'], tab.id);
    expect((backend.created.single['cols'], backend.created.single['rows']), (80, 24));
    expect(backend.created.single['shellPath'], isNull);
    // Hold first, then attach.
    expect(backend.calls.indexOf('retain:${tab.id}'), lessThan(backend.calls.indexOf('attach:${tab.id}')));
  });

  test('listed terminals are restored; the first running one is selected', () async {
    final fake = FakeTerminalBackend(
      terminals: [
        infoJson('done', title: 'build', state: 'exited', exitCode: 2),
        infoJson('t1', title: 'server'),
      ],
    )..screens['t1'] = sampleScreen;
    await open(fake);
    final state = read();
    expect(state.tabs.map((t) => t.id), ['done', 't1']);
    expect(state.selectedId, 't1');
    expect(backend.created, isEmpty);
    expect(state.tabs.first.phase, TerminalPhase.ended);
    expect(state.tabs.first.exitCode, 2);
    final live = state.selected!;
    expect(live.phase, TerminalPhase.live);
    expect(live.terminal.buffer.lines[1].toString().trim(), 'M app/lib/ui/terminal/terminal_page.dart');
  });

  test('typing and resizing go to the attachment', () async {
    await open(FakeTerminalBackend());
    final tab = read().selected!;
    final attach = backend.attachOf(tab.id);
    tab.terminal.textInput('ls -la\r');
    container.read(terminalWorkspaceProvider(_session).notifier).resize(tab.id, 52, 30);
    await _settle();
    expect(attach.written, 'ls -la\r');
    expect(attach.resizes.single, {'type': 'resize', 'sequence': 2, 'cols': 52, 'rows': 30});
    // Output lands in the screen without a state change.
    final before = read();
    attach.output('hello\r\n');
    await _settle();
    expect(identical(before, read()), isTrue);
    expect(tab.terminal.buffer.lines[0].toString().trim(), 'hello');
  });

  test('a second terminal is created at the measured screen size', () async {
    final workspace = await open(FakeTerminalBackend());
    workspace.resize(read().selected!.id, 47, 31);
    await workspace.newTerminal(shellPath: '/usr/bin/fish');
    await _settle();
    expect(read().tabs, hasLength(2));
    expect(read().selectedId, read().tabs.last.id);
    expect(backend.created.last, containsPair('cols', 47));
    expect(backend.created.last, containsPair('rows', 31));
    expect(backend.created.last, containsPair('shellPath', '/usr/bin/fish'));
    // The choice is remembered for the next one while it is installed.
    await workspace.newTerminal();
    await _settle();
    expect(backend.created.last['shellPath'], '/usr/bin/fish');
  });

  test('the limit reached is a failed tab that can be retried', () async {
    final fake = FakeTerminalBackend()
      ..createError = const DshRemoteException('terminal/limit-reached', 'Session terminal limit reached', {
        'limit': 8,
      });
    final workspace = await open(fake);
    final tab = read().selected!;
    expect(tab.phase, TerminalPhase.failed);
    expect(tab.message, TerminalCopy.limit);
    fake.createError = null;
    await workspace.retry(tab.id);
    await _settle();
    expect(read().selected!.phase, TerminalPhase.live);
    expect(fake.created.map((c) => c['id']).toSet(), {tab.id}, reason: 'the same id is retried');
  });

  test('exit ends the tab; 新建终端 replaces it in place and closes the old one', () async {
    final workspace = await open(
      FakeTerminalBackend(
        terminals: [
          infoJson('a', title: 'one'),
          infoJson('b', title: 'two'),
        ],
      ),
    );
    backend.attachOf('a').state(infoJson('a', title: 'one', state: 'exited', exitCode: 130), writable: false);
    await _settle();
    final ended = read().tabs.first;
    expect(ended.phase, TerminalPhase.ended);
    expect(ended.exitCode, 130);
    expect(ended.writable, isFalse);

    await workspace.newTerminal(replacing: 'a');
    await _settle();
    expect(read().tabs, hasLength(2));
    expect(read().tabs.first.id, isNot('a'));
    expect(read().tabs.last.id, 'b');
    expect(read().selectedId, read().tabs.first.id);
    expect(backend.calls, contains('close:a'));
    expect(backend.attachOf('a').cancelled, isTrue);
  });

  test('a dropped link keeps the screen and reattaches when the link is back', () async {
    final fake = FakeTerminalBackend()..autoSnapshot = true;
    await open(fake);
    final id = read().selected!.id;
    final first = read().selected!.terminal;
    fake.attachOf(id).output('still here');
    fake.attachOf(id).lose();
    await _settle();
    expect(read().selected!.phase, TerminalPhase.disconnected);
    expect(identical(read().selected!.terminal, first), isTrue);

    fake.reconnects.add(null);
    await _settle();
    expect(fake.attaches.where((a) => a.id == id), hasLength(2));
    expect(read().selected!.phase, TerminalPhase.live);
    expect(identical(read().selected!.terminal, first), isFalse, reason: 'a new snapshot, a new screen');
  });

  test('resuming the app reattaches dropped tabs only', () async {
    final workspace = await open(FakeTerminalBackend(terminals: [infoJson('a'), infoJson('b')]));
    backend.attachOf('a').lose();
    await _settle();
    workspace.reconnectAll();
    await _settle();
    expect(backend.attaches.where((a) => a.id == 'a'), hasLength(2));
    expect(backend.attaches.where((a) => a.id == 'b'), isEmpty);
  });

  test('tabs not looked at are held but not attached until shown', () async {
    final workspace = await open(
      FakeTerminalBackend(
        terminals: [
          infoJson('a'),
          infoJson('b'),
          infoJson('c', state: 'exited', exitCode: 0),
        ],
      )..screens['c'] = 'bye\r\n',
    );
    expect(backend.calls.where((c) => c.startsWith('retain:')).toSet(), {'retain:a', 'retain:b', 'retain:c'});
    expect(backend.attaches.map((a) => a.id), ['a'], reason: 'only the shown tab takes input control');
    expect(read().tabs[1].phase, TerminalPhase.connecting);
    expect(read().tabs[2].phase, TerminalPhase.ended);

    workspace.select('c');
    await _settle();
    expect(backend.attaches.map((a) => a.id), ['a', 'c']);
    expect(read().tabs[2].phase, TerminalPhase.ended);
    expect(read().tabs[2].terminal.buffer.lines[0].toString().trim(), 'bye');
    workspace
      ..select('a')
      ..select('c');
    await _settle();
    expect(backend.attaches.map((a) => a.id), ['a', 'c'], reason: 'shown tabs stay attached');
  });

  test('a terminal the Host no longer has turns missing', () async {
    final workspace = await open(FakeTerminalBackend(terminals: [infoJson('a')]));
    backend.attachOf('a').lose();
    backend.host.remove('a'); // the engine restarted
    await _settle();
    workspace.reconnect('a');
    await _settle();
    expect(read().selected!.phase, TerminalPhase.missing);
  });

  test('another device taking input makes the tab read-only; 接管 takes it back', () async {
    final workspace = await open(FakeTerminalBackend(terminals: [infoJson('a')]));
    backend.attachOf('a').state(infoJson('a'), writable: false);
    await _settle();
    expect(read().selected!.readOnly, isTrue);
    read().selected!.terminal.textInput('x');
    await _settle();
    expect(backend.attachOf('a').written, isEmpty);

    workspace.reconnect('a');
    await _settle();
    expect(read().selected!.readOnly, isFalse);
    expect(read().selected!.writable, isTrue);
  });

  test('closing a tab ends its terminal and selects a neighbour', () async {
    final workspace = await open(FakeTerminalBackend(terminals: [infoJson('a'), infoJson('b'), infoJson('c')]));
    workspace.select('b');
    workspace.closeTab('b');
    await _settle();
    expect(read().tabs.map((t) => t.id), ['a', 'c']);
    expect(read().selectedId, 'c');
    expect(backend.calls, contains('close:b'));
    expect(read().selected!.phase, TerminalPhase.live, reason: 'the neighbour shown next attaches');
    workspace
      ..closeTab('a')
      ..closeTab('c');
    await _settle();
    expect(read().tabs, isEmpty);
    expect(read().selected, isNull);
    expect(backend.created, isEmpty, reason: 'closing the last tab does not start a new one');
  });

  test('rename updates the title; a refused rename puts it back', () async {
    final workspace = await open(FakeTerminalBackend(terminals: [infoJson('a')]));
    expect(await workspace.rename('a', '  构建  '), isTrue);
    expect(read().selected!.title, '构建');
    expect(await workspace.rename('a', '   '), isFalse);
    expect(read().selected!.title, '构建');
  });

  Future<TerminalWorkspace> openRename(_PendingRenameBackend fake) async {
    backend = fake;
    container = ProviderContainer(overrides: [terminalBackendProvider(_session).overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final ready = Completer<void>();
    container.listen(terminalWorkspaceProvider(_session), (_, next) {
      if (next.selected?.phase == TerminalPhase.live && !ready.isCompleted) ready.complete();
    });
    await ready.future;
    return container.read(terminalWorkspaceProvider(_session).notifier);
  }

  test('a rename failure after page disposal returns false without updating disposed state', () async {
    final fake = _PendingRenameBackend();
    final workspace = await openRename(fake);
    final result = workspace.rename('a', '构建');
    await fake.renameStarted.future;
    expect(read().selected!.title, '构建');
    container.dispose();
    final checked = expectLater(result, completion(isFalse));
    fake.renameResult.completeError(const DshTransportException('connection closed'));
    await checked;
  });

  test('a previous backend rename failure does not change the rebuilt terminal', () async {
    final previous = _PendingRenameBackend();
    final workspace = await openRename(previous);
    final result = workspace.rename('a', '旧请求');
    await previous.renameStarted.future;
    final current = _PendingRenameBackend(title: '新主机');
    final ready = Completer<void>();
    container.listen(terminalWorkspaceProvider(_session), (_, next) {
      if (next.selected?.phase == TerminalPhase.live && next.selected?.title == '新主机' && !ready.isCompleted) {
        ready.complete();
      }
    });
    container.updateOverrides([terminalBackendProvider(_session).overrideWithValue(current)]);
    await container.pump();
    await ready.future;
    expect(identical(container.read(terminalWorkspaceProvider(_session).notifier), workspace), isTrue);
    expect(read().selected!.title, '新主机');
    final checked = expectLater(result, completion(isFalse));
    previous.renameResult.completeError(const DshTransportException('old connection closed'));
    await checked;
    expect(read().selected!.title, '新主机');
  });

  test('a current backend rename failure still restores the previous title', () async {
    final fake = _PendingRenameBackend();
    final workspace = await openRename(fake);
    final result = workspace.rename('a', '构建');
    await fake.renameStarted.future;
    expect(read().selected!.title, '构建');
    final checked = expectLater(result, completion(isFalse));
    fake.renameResult.completeError(const DshTransportException('rename refused'));
    await checked;
    expect(read().selected!.title, 'bash');
  });

  test('leaving the page detaches without closing terminals', () async {
    await open(FakeTerminalBackend(terminals: [infoJson('a')]));
    container.dispose();
    await _settle();
    expect(backend.attachOf('a').cancelled, isTrue);
    expect(backend.calls.where((c) => c.startsWith('close:')), isEmpty);
  });

  test('a listing failure can be retried', () async {
    final fake = FakeTerminalBackend()..listError = const DshTransportException('down');
    final workspace = await open(fake);
    expect(read().error, TerminalCopy.offline);
    fake.listError = null;
    await workspace.reload();
    await _settle();
    expect(read().error, isNull);
    expect(read().tabs, hasLength(1));
  });

  test('a Host that turned the terminal off says so, also inside the first parallel load', () async {
    final fake = FakeTerminalBackend()
      ..listError = const DshRemoteException('TERMINAL_DISABLED', 'off', {'remote': true});
    final workspace = await open(fake);
    expect(read().error, TerminalCopy.disabledOnHost, reason: 'not "engine unreachable"');
    fake.listError = null;
    await workspace.reload();
    await _settle();
    expect(read().error, isNull);
  });

  test('a Remote Host that announced no terminal opens on that message and still retries', () async {
    final fake = FakeTerminalBackend()..offOnHost = true;
    final workspace = await open(fake);
    expect(read().error, TerminalCopy.disabledOnHost);
    expect(fake.calls, isEmpty);
    await workspace.reload();
    await _settle();
    expect(read().error, isNull, reason: 'the owner may have turned it on since: calls work without reconnecting');
  });

  test('the link coming back lists again when nothing could be listed', () async {
    final fake = FakeTerminalBackend()..offOnHost = true;
    await open(fake);
    expect(read().error, TerminalCopy.disabledOnHost);
    fake.reconnects.add(null);
    await _settle();
    expect(read().error, isNull, reason: 'the owner turned it on and the link returned');
    expect(read().tabs, hasLength(1));
  });

  test('connections without terminal support and no connection', () async {
    await open(FakeTerminalBackend(supported: false));
    expect(read().supported, isFalse);
    expect(backend.calls, isEmpty);

    final none = ProviderContainer(overrides: [terminalBackendProvider.overrideWith((ref, id) => null)]);
    addTearDown(none.dispose);
    expect(none.read(terminalWorkspaceProvider(_session)).offline, isTrue);
  });

  test('font size: clamped half steps, remembered', () async {
    final fonts = ProviderContainer();
    addTearDown(fonts.dispose);
    fonts.listen(terminalFontSizeProvider, (_, _) {});
    expect(fonts.read(terminalFontSizeProvider), TerminalFontSize.fallback);
    fonts.read(terminalFontSizeProvider.notifier).set(15.26);
    expect(fonts.read(terminalFontSizeProvider), 15.5);
    fonts.read(terminalFontSizeProvider.notifier).set(100);
    expect(fonts.read(terminalFontSizeProvider), TerminalFontSize.max);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('terminal.fontSize'), TerminalFontSize.max);

    final again = ProviderContainer();
    addTearDown(again.dispose);
    again.listen(terminalFontSizeProvider, (_, _) {});
    await _settle();
    expect(again.read(terminalFontSizeProvider), TerminalFontSize.max);
  });
}

class _PendingRenameBackend extends FakeTerminalBackend {
  _PendingRenameBackend({String title = 'bash'}) : super(terminals: [infoJson('a', title: title)]);

  final renameStarted = Completer<void>();
  final renameResult = Completer<void>();

  @override
  Future<void> rename(String id, String title) {
    calls.add('rename');
    renameStarted.complete();
    return renameResult.future;
  }
}
