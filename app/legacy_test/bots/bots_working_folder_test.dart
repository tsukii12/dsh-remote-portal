import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/bots/working_folder_sheet.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

const project = '/srv/projects/Project 中国';
const old = '/srv/previous';
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final save = find.byKey(const ValueKey('folder-save'));
  final choice = find.byKey(const ValueKey('folder:$project'));
  final confirm = find.byKey(const ValueKey('folder-confirm'));
  Future<({FakeDsBotTransport fake, Map<String, Object?> team, Map entity, ProviderContainer container})> open(
    WidgetTester tester, {
    bool room = false,
    bool readOnly = false,
    bool details = false,
    Object? Function(Map<String, Object?>)? folders,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    final team = sampleTeam(working: false);
    final entity = room ? (team['rooms'] as List).first as Map : (team['bots'] as List)[1] as Map;
    entity['workDir'] = old;
    if (readOnly) team['readOnly'] = 'elsewhere';
    final fake = FakeDsBotTransport(team: team)..helloOnFeed = false;
    fake.handlers['folders'] =
        folders ??
        (_) => {
          'team': '/srv/team',
          'picker': null,
          'folders': [
            {'title': 'Project 中国', 'path': project},
          ],
        };
    fake.handlers['update-bot'] = fake.handlers['update-room'] = (_) => true;
    usePhoneView(tester);
    tester.view.physicalSize = const Size(640, 1688);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      goldenApp(
        brightness: brightness,
        overrides: dsBotOverrides(fake),
        home: details
            ? (room ? const RoomDetailsPage(roomId: 'r1') : BotDetailsPage(botId: entity['id'] as String))
            : Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed: ref.watch(dsBotProvider).ready
                          ? () => showWorkingFolderSheet(
                              context,
                              botId: room ? null : entity['id'] as String,
                              roomId: room ? 'r1' : null,
                              workDir: old,
                            )
                          : null,
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
      ),
    );
    await frames(tester);
    if (details) {
      final entry = find.byKey(ValueKey('${room ? 'room' : 'bot'}-working-folder'));
      await tester.scrollUntilVisible(entry, 300, scrollable: find.byType(Scrollable).first);
      expect(find.text(old), findsWidgets);
      await tester.tap(entry);
    } else {
      await tester.tap(find.text('Open'));
    }
    await frames(tester);
    return (
      fake: fake,
      team: team,
      entity: entity,
      container: ProviderScope.containerOf(tester.element(find.byType(WorkingFolderSheet))),
    );
  }

  Future<void> select(WidgetTester tester) async {
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
    await tester.ensureVisible(save);
    await tester.tap(save);
    await frames(tester);
  }

  for (final room in [false, true]) {
    final endpoint = room ? 'update-room' : 'update-bot';
    testWidgets('$endpoint details displays current path and writes only after confirmation', (tester) async {
      final h = await open(tester, room: room, details: true);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await select(tester);
      expect(h.fake.endpoints, isNot(contains(endpoint)));
      expect(find.text(project), findsWidgets);
      await tester.tap(confirm);
      await frames(tester);
      expect(h.fake.calls.lastWhere((c) => c.$1 == endpoint).$2, {'id': h.entity['id'], 'workDir': project});
      expect(find.byType(WorkingFolderSheet), findsNothing);
    });
    testWidgets('$endpoint default sends empty string, not omitted or null', (tester) async {
      final h = await open(tester, room: room);
      await tester.tap(find.byKey(const ValueKey('folder-default')));
      await tester.pump();
      await tester.tap(save);
      await frames(tester);
      await tester.tap(confirm);
      await frames(tester);
      expect(h.fake.calls.lastWhere((c) => c.$1 == endpoint).$2, {'id': h.entity['id'], 'workDir': ''});
    });
    testWidgets('$endpoint read-only has directory information but no editable choice', (tester) async {
      final h = await open(tester, room: room, readOnly: true, details: true);
      expect(find.text(old), findsWidgets);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(tester.widget<RadioListTile<String>>(choice).enabled, isFalse);
      expect(h.fake.endpoints, isNot(contains(endpoint)));
    });
    testWidgets('$endpoint save failure retains choice and prevents duplicate writes', (tester) async {
      final h = await open(tester, room: room);
      final pending = Completer<Object?>();
      h.fake.handlers[endpoint] = (_) => pending.future;
      await select(tester);
      await tester.tap(confirm);
      await frames(tester);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      pending.completeError(DshRemoteException('bot/refused', 'Directory no longer exists'));
      await frames(tester);
      expect(find.textContaining('主机拒绝了此目录'), findsOneWidget);
      expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>)).groupValue, project);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(h.fake.endpoints.where((e) => e == endpoint), hasLength(1));
    });
    testWidgets('$endpoint reconnect during confirmation prevents write', (tester) async {
      final h = await open(tester, room: room);
      await select(tester);
      h.container.read(dsBotProvider.notifier).retry();
      await frames(tester);
      await tester.tap(confirm);
      await frames(tester);
      expect(h.fake.endpoints, isNot(contains(endpoint)));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    });
    testWidgets('$endpoint late write cannot close old editor after reconnect', (tester) async {
      final h = await open(tester, room: room);
      final pending = Completer<Object?>();
      h.fake.handlers[endpoint] = (_) => pending.future;
      await select(tester);
      await tester.tap(confirm);
      await frames(tester);
      h.container.read(dsBotProvider.notifier).retry();
      await frames(tester);
      final states = h.fake.endpoints.where((e) => e == 'state').length;
      pending.complete(true);
      await frames(tester);
      expect(find.byType(WorkingFolderSheet), findsOneWidget);
      expect(h.fake.endpoints.where((e) => e == 'state'), hasLength(states));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    });
  }
  for (final room in [false, true]) {
    for (final change in ['readonly', 'removed', 'boot']) {
      testWidgets('folder confirmation checks $change for room=$room', (tester) async {
        final h = await open(tester, room: room);
        await select(tester);
        if (change == 'boot') {
          h.fake.handlers['hello'] = (_) => {...h.fake.helloAnswer(), 'boot': 'next-boot'};
          h.fake.emit('hello', {'api': 1, 'boot': 'next-boot', 'seq': 0, 'revision': 8});
        } else {
          h.team['revision'] = 8;
          if (change == 'readonly') h.team['readOnly'] = 'owned elsewhere';
          if (change == 'removed') {
            final key = room ? 'rooms' : 'bots';
            h.team[key] = (h.team[key] as List).where((e) => (e as Map)['id'] != h.entity['id']).toList();
          }
          await h.container.read(dsBotProvider.notifier).refresh();
        }
        await frames(tester);
        await tester.tap(confirm);
        await frames(tester);
        expect(h.fake.endpoints, isNot(contains(room ? 'update-room' : 'update-bot')));
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
      });
    }
  }
  testWidgets('cancelling full path confirmation retains choice without writing', (tester) async {
    final h = await open(tester);
    await select(tester);
    await tester.tap(find.text('取消'));
    await frames(tester);
    expect(h.fake.endpoints, isNot(contains('update-bot')));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  });
  for (final operation in ['folders', 'update-bot']) {
    testWidgets('closing sheet before late $operation failure is safe', (tester) async {
      final pending = Completer<Object?>();
      final h = await open(tester, folders: operation == 'folders' ? (_) => pending.future : null);
      if (operation == 'update-bot') {
        h.fake.handlers[operation] = (_) => pending.future;
        await select(tester);
        await tester.tap(confirm);
        await frames(tester);
      }
      Navigator.of(tester.element(find.byType(WorkingFolderSheet))).pop();
      await frames(tester);
      pending.completeError(StateError('late after close'));
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(WorkingFolderSheet), findsNothing);
    });
  }
  testWidgets('catalog load error retries and never permits an unlisted path', (tester) async {
    final h = await open(tester, folders: (_) => throw StateError('folder offline'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    h.fake.handlers['folders'] = (_) => {'team': '/srv/team', 'folders': []};
    await tester.tap(find.text('重试'));
    await frames(tester);
    expect(find.byKey(const ValueKey('folder-default')), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.text(old), findsWidgets);
  });
  testWidgets('late catalog after reconnect never enables old panel', (tester) async {
    final pending = Completer<Object?>();
    final h = await open(tester, folders: (_) => pending.future);
    h.container.read(dsBotProvider.notifier).retry();
    await frames(tester);
    pending.complete({
      'team': '/srv/team',
      'folders': [
        {'path': project, 'title': 'late'},
      ],
    });
    await frames(tester);
    expect(choice, findsNothing);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });
  testWidgets('external workDir change invalidates open draft', (tester) async {
    final h = await open(tester);
    await select(tester);
    h.entity['workDir'] = '/srv/changed';
    h.team['revision'] = 8;
    await h.container.read(dsBotProvider.notifier).refresh();
    await frames(tester);
    await tester.tap(confirm);
    await frames(tester);
    expect(h.fake.endpoints, isNot(contains('update-bot')));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('working folder 320dp/$scale/${brightness.name}', (tester) async {
        await open(tester, brightness: brightness, scale: scale);
        await select(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(confirm).right, lessThanOrEqualTo(320));
      });
    }
    testWidgets('folder golden ${brightness.name}', (tester) async {
      await open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/working_folder_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}
