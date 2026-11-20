import 'dart:async';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_controls_state.dart';
import 'package:flutter_test/flutter_test.dart';

DshUiInput input({String name = 'name', DshUiAction? onChange, bool required = false, int maxLength = 256}) =>
    DshUiInput(
      path: 'view.$name',
      kind: 'textField',
      label: name,
      bind: 'data.form.$name',
      value: '',
      onChange: onChange,
      required: required,
      maxLength: maxLength,
    );
DshUiControlContainer form(List<DshUiInput> fields) => DshUiControlContainer(
  path: 'view',
  kind: 'form',
  sections: [DshUiControlSection('', fields)],
  submit: const DshUiAction('save'),
);

void main() {
  testWidgets('queued buttons and submit retain each real gesture time', (tester) async {
    final epoch = DateTime.utc(2026, 10, 27);
    var now = epoch;
    final first = Completer<bool>();
    final field = input();
    final sent = <PluginAction>[];
    final state = PluginDraftController(clock: () => now)
      ..syncInputs([field])
      ..setHandler((action) {
        sent.add(action);
        return action.id == 'first' ? first.future : Future.value(true);
      });
    addTearDown(state.dispose);
    const original = PluginAction(id: 'first', source: PluginActionSource.button, path: 'view.first');
    final a = state.invoke(original);
    now = epoch.add(const Duration(seconds: 1));
    final b = state.invoke(const PluginAction(id: 'second', source: PluginActionSource.button, path: 'view.second'));
    now = epoch.add(const Duration(seconds: 2));
    final submitted = state.submit(form([field]));
    now = epoch.add(const Duration(seconds: 10));
    expect(sent, hasLength(1));
    first.complete(true);
    await tester.pump();
    expect(await Future.wait([a, b, submitted]), [true, true, true]);
    expect(sent.map((a) => a.gestureAt), [
      epoch,
      epoch.add(const Duration(seconds: 1)),
      epoch.add(const Duration(seconds: 2)),
    ]);
    expect(original.gestureAt, isNull, reason: 'Stamping never mutates an existing action');
    final preserved = epoch.subtract(const Duration(seconds: 5));
    await state.invoke(
      PluginAction(id: 'stamped', source: PluginActionSource.button, path: 'view.stamped', gestureAt: preserved),
    );
    expect(sent.last.gestureAt, preserved, reason: 'A pre-existing host stamp cannot be renewed at dispatch');
  });

  testWidgets('different explicit buttons on one component are not coalesced', (tester) async {
    final first = Completer<bool>();
    final sent = <String>[];
    final state = PluginDraftController()
      ..setHandler((a) async {
        sent.add(a.id);
        return a.id == 'first' ? first.future : true;
      });
    addTearDown(state.dispose);
    final a = state.invoke(const PluginAction(id: 'first', source: PluginActionSource.button, path: 'view'));
    final b = state.invoke(const PluginAction(id: 'second', source: PluginActionSource.button, path: 'view'));
    final c = state.invoke(const PluginAction(id: 'third', source: PluginActionSource.button, path: 'view'));
    expect(sent, ['first']);
    first.complete(true);
    await tester.pump();
    expect(await Future.wait([a, b, c]), [true, true, true]);
    expect(sent, ['first', 'second', 'third']);
  });

  testWidgets('different fields share a maximum four-change-per-second lane', (tester) async {
    final first = input(name: 'first', onChange: const DshUiAction('changed'));
    final second = input(name: 'second', onChange: const DshUiAction('changed'));
    final sent = <PluginAction>[];
    final state = PluginDraftController()
      ..syncInputs([first, second])
      ..setHandler((a) async {
        sent.add(a);
        return true;
      });
    addTearDown(state.dispose);
    state.edit(first, 'a');
    state.edit(second, 'b');
    await tester.pump(const Duration(milliseconds: 250));
    expect(sent, hasLength(1));
    await tester.pump(const Duration(milliseconds: 249));
    expect(sent, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, hasLength(2));
    expect(sent.last.args['bind'], second.bind);
    state.setHandler(null);
  });

  testWidgets('change coalesces trailing edits and sends at 250 ms', (tester) async {
    final field = input(onChange: const DshUiAction('changed'));
    final sent = <PluginAction>[];
    final state = PluginDraftController()
      ..syncInputs([field])
      ..setHandler((action) async {
        sent.add(action);
        return true;
      });
    addTearDown(state.dispose);
    state.edit(field, 'a');
    await tester.pump(const Duration(milliseconds: 100));
    state.edit(field, 'ab');
    await tester.pump(const Duration(milliseconds: 249));
    expect(sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent, hasLength(1));
    expect(sent.single.source, PluginActionSource.change);
    expect(sent.single.gestureAt, isNull, reason: 'A change timer never manufactures user authority');
    expect(sent.single.args, {'bind': 'data.form.name', 'value': 'ab'});
    expect(state.data, {
      'form': {'name': 'ab'},
    });
    state.setHandler(null);
  });

  testWidgets('one lane, frozen submit and newer edits survive older patch', (tester) async {
    final field = input(onChange: const DshUiAction('changed'));
    final sent = <PluginAction>[];
    final replies = <Completer<bool>>[];
    final state =
        PluginDraftController(
            data: {
              'form': {'name': 'original'},
            },
          )
          ..syncInputs([field])
          ..setHandler((action) {
            sent.add(action);
            final reply = Completer<bool>();
            replies.add(reply);
            return reply.future;
          });
    addTearDown(state.dispose);
    state.edit(field, 'a');
    await tester.pump(const Duration(milliseconds: 250));
    state.edit(field, 'b');
    await tester.pump(const Duration(milliseconds: 250));
    final submitted = state.submit(form([field]));
    state.edit(field, 'c');
    await tester.pump(const Duration(milliseconds: 250));
    expect(sent, hasLength(1), reason: 'queued requests cannot overlap the running change');
    replies[0].complete(true);
    await tester.pump();
    expect(sent, hasLength(2));
    expect(sent[1].source, PluginActionSource.submit);
    expect(sent[1].args, {
      'values': {'data.form.name': 'b'},
    });
    state.syncRemote({
      'form': {'name': 'normalized b'},
    });
    replies[1].complete(true);
    await tester.pump();
    expect(await submitted, isTrue);
    expect(state.value(field), 'c');
    expect(sent, hasLength(3));
    expect(sent[2].args['value'], 'c');
    state.syncRemote({
      'form': {'name': 'normalized c'},
    });
    replies[2].complete(true);
    await tester.pump();
    expect(state.dirty(field.bind!), isFalse);
    expect(state.data, {
      'form': {'name': 'normalized c'},
    });
    state.setHandler(null);
  });

  testWidgets('submit-only edits never invoke before valid submission', (tester) async {
    final field = input(required: true);
    var calls = 0;
    final state = PluginDraftController()
      ..syncInputs([field])
      ..setHandler((_) async {
        calls++;
        return true;
      });
    addTearDown(state.dispose);
    expect(await state.submit(form([field])), isFalse);
    expect(state.errors[field.bind], isNotNull);
    state.edit(field, 'ready');
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    expect(await state.submit(form([field])), isTrue);
    expect(calls, 1);
    expect(state.errors, isEmpty);
  });

  testWidgets('failed invokes preserve drafts and show inline errors', (tester) async {
    final field = input();
    final state = PluginDraftController()
      ..syncInputs([field])
      ..setHandler((_) async => throw StateError('offline'));
    addTearDown(state.dispose);
    state.edit(field, 'retain me');
    expect(await state.submit(form([field])), isFalse);
    expect(state.value(field), 'retain me');
    expect(state.dirty(field.bind!), isTrue);
    expect(state.errors[field.bind], isNotNull);
    expect(state.formErrors['view'], isNotNull);
  });

  testWidgets('disconnect cancels pending changes with no automatic replay', (tester) async {
    final field = input(onChange: const DshUiAction('changed'));
    var calls = 0;
    Future<bool> send(PluginAction _) async {
      calls++;
      return true;
    }

    final state = PluginDraftController()
      ..syncInputs([field])
      ..setHandler(send);
    addTearDown(state.dispose);
    state.edit(field, 'offline draft');
    state.setHandler(null);
    await tester.pump(const Duration(seconds: 1));
    state.setHandler(send);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    expect(state.value(field), 'offline draft');
    expect(await state.submit(form([field])), isTrue);
    expect(calls, 1);
  });

  testWidgets('removing a field cancels its queued change and state', (tester) async {
    final first = input(name: 'first', onChange: const DshUiAction('changed'));
    final second = input(name: 'second', onChange: const DshUiAction('changed'));
    final reply = Completer<bool>();
    final sent = <PluginAction>[];
    final state = PluginDraftController()
      ..syncInputs([first, second])
      ..setHandler((action) {
        sent.add(action);
        return reply.future;
      });
    addTearDown(state.dispose);
    state.edit(first, 'running');
    await tester.pump(const Duration(milliseconds: 250));
    state.edit(second, 'queued');
    await tester.pump(const Duration(milliseconds: 250));
    state.syncInputs([first]);
    reply.complete(true);
    await tester.pump();
    expect(sent, hasLength(1));
    expect(state.data, {
      'form': {'first': 'running'},
    });
  });

  testWidgets('4 KiB invoke.value is enforced before sending, never truncated', (tester) async {
    final first = input(name: 'first', maxLength: 2000);
    final second = input(name: 'second', maxLength: 2000);
    var calls = 0;
    final state = PluginDraftController()
      ..syncInputs([first, second])
      ..setHandler((_) async {
        calls++;
        return true;
      });
    addTearDown(state.dispose);
    state.edit(first, '中' * 1500);
    state.edit(second, '文' * 1500);
    expect(await state.submit(form([first, second])), isFalse);
    expect(calls, 0);
    expect(state.formErrors['view'], isNotNull);
    expect(state.value(first), '中' * 1500);
  });

  testWidgets('null draft, copy-on-write and disposal preserve boundaries', (tester) async {
    final field = input(onChange: const DshUiAction('changed'));
    final remote = {
      'form': {'name': 'remote'},
      'other': 7,
    };
    var calls = 0;
    final state = PluginDraftController(data: remote)
      ..syncInputs([field])
      ..setHandler((_) async {
        calls++;
        return true;
      });
    state.edit(field, null);
    expect(state.value(field), isNull);
    expect(remote['form'], {'name': 'remote'});
    expect(state.data, {
      'form': {'name': null},
      'other': 7,
    });
    state.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
  });
}
