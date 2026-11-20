import 'dart:async';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _session = 'shell-owner';
const _bash = TerminalShell(path: '/bin/bash', name: 'bash', args: ['-i']);
const _fish = TerminalShell(path: '/usr/bin/fish', name: 'fish', args: ['-i']);

void main() {
  late ProviderContainer container;
  final provider = terminalWorkspaceProvider(_session);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TerminalWorkspace.viewSizeWait = Duration.zero;
    TerminalWorkspace.resizeSettle = Duration.zero;
  });
  tearDown(() {
    TerminalWorkspace.viewSizeWait = const Duration(milliseconds: 400);
    TerminalWorkspace.resizeSettle = const Duration(milliseconds: 150);
  });

  Future<TerminalWorkspace> open(_ShellBackend backend) async {
    container = ProviderContainer(overrides: [terminalBackendProvider(_session).overrideWithValue(backend)]);
    addTearDown(container.dispose);
    final ready = Completer<void>();
    container.listen(provider, (_, next) {
      if (next.selected?.phase == TerminalPhase.live && !ready.isCompleted) ready.complete();
    });
    await ready.future;
    return container.read(provider.notifier);
  }

  Future<void> replace(_ShellBackend? backend, TerminalWorkspace workspace) async {
    final ready = Completer<void>();
    final sub = container.listen(provider, (_, next) {
      final matches = backend == null
          ? next.offline
          : next.selected?.phase == TerminalPhase.live && next.selected?.title == backend.title;
      if (matches && !ready.isCompleted) ready.complete();
    });
    try {
      container.updateOverrides([terminalBackendProvider(_session).overrideWithValue(backend)]);
      await container.pump();
      await ready.future;
      expect(container.read(provider.notifier), same(workspace));
    } finally {
      sub.close();
    }
  }

  test('a current shell result is cached for its backend', () async {
    final backend = _ShellBackend('current', const [_bash]);
    final workspace = await open(backend);
    expect(await workspace.shells(), [_bash]);
    expect(await workspace.shells(), [_bash]);
    expect(backend.calls.where((call) => call == 'shells'), hasLength(1));
  });

  test('a previous shell result cannot replace the current backend cache', () async {
    final previous = _ShellBackend('previous', const [_fish])..pending = Completer<List<TerminalShell>>();
    final workspace = await open(previous);
    final oldResult = workspace.shells();
    expect(previous.calls.where((call) => call == 'shells'), hasLength(1));
    final current = _ShellBackend('current', const [_bash]);
    await replace(current, workspace);
    expect(await workspace.shells(), [_bash]);
    previous.pending!.complete(const [_fish]);
    expect(await oldResult, isEmpty);
    expect(await workspace.shells(), [_bash]);
    expect(current.calls.where((call) => call == 'shells'), hasLength(1));
  });

  test('a late shell result cannot restore the cache while offline', () async {
    final previous = _ShellBackend('previous', const [_fish])..pending = Completer<List<TerminalShell>>();
    final workspace = await open(previous);
    final oldResult = workspace.shells();
    await replace(null, workspace);
    previous.pending!.complete(const [_fish]);
    expect(await oldResult, isEmpty);
    expect(await workspace.shells(), isEmpty);
    expect(container.read(provider).offline, isTrue);
  });

  test('new terminals do not reuse a remembered shell from a retired backend result', () async {
    SharedPreferences.setMockInitialValues({'terminal.shell': _fish.path});
    final previous = _ShellBackend('previous', const [_fish])..pending = Completer<List<TerminalShell>>();
    final workspace = await open(previous);
    final oldResult = workspace.shells();
    final current = _ShellBackend('current', const [_bash]);
    await replace(current, workspace);
    previous.pending!.complete(const [_fish]);
    await oldResult;
    await workspace.newTerminal();
    expect(current.created.single['shellPath'], isNull);
    expect(current.calls.where((call) => call == 'shells'), hasLength(1));
    expect(previous.created, isEmpty);
  });

  test('a current shell error still propagates and a later request can retry', () async {
    final backend = _ShellBackend('current', const [_bash])..pending = Completer<List<TerminalShell>>();
    final workspace = await open(backend);
    const error = DshTransportException('shell listing failed');
    final result = expectLater(workspace.shells(), throwsA(same(error)));
    backend.pending!.completeError(error);
    await result;
    backend.pending = null;
    expect(await workspace.shells(), [_bash]);
    expect(backend.calls.where((call) => call == 'shells'), hasLength(2));
  });
}

class _ShellBackend extends FakeTerminalBackend {
  _ShellBackend(this.title, this.installed) : super(terminals: [infoJson('a', title: title)]);

  final String title;
  final List<TerminalShell> installed;
  Completer<List<TerminalShell>>? pending;

  @override
  Future<List<TerminalShell>> shells() {
    calls.add('shells');
    return pending?.future ?? Future.value(installed);
  }
}
