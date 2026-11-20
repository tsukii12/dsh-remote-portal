import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

MacroMessage _user(int? epoch) => MacroMessage(
  text: 'user',
  isUser: true,
  sentAt: epoch == null ? null : DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true),
);

String _idle(MacroContext context, bool legacy) => legacy
    ? const LegacyMacroEngine().expand('LEFT{{idle_duration}}RIGHT', context)
    : const MacroEngine().expand('LEFT{{idleDuration}}RIGHT', context);

void main() {
  test('idleDuration preserves long spans, history selection and microsecond contexts in both modes', () {
    // Eight inputs from the sole fixed-ST 7e8663cd/Moment 2.30.1 idle probe.
    // Epochs, history flags and en/zh-cn literals are from its actual records.
    const ordinary = 1704110400000;
    const early = -6373557619200000;
    const late = 6249223180800000;
    const assistant = MacroMessage(text: 'assistant');
    final rows = <(String, int, List<MacroMessage>, String, String)>[
      (
        'ordinary_two_minutes',
        ordinary,
        [_user(1704106800000), _user(1704110280000), const MacroMessage(text: 'system', isSystem: true), assistant],
        '2 minutes',
        '2 分钟',
      ),
      ('long_forward', late, [_user(early), _user(ordinary)], '400000 years', '400000 年'),
      ('long_reverse', early, [_user(late), _user(ordinary)], '400000 years', '400000 年'),
      (
        'below_microsecond_wrap',
        4549502678400000,
        [_user(-4673837030400000), _user(ordinary)],
        '292276 years',
        '292276 年',
      ),
      (
        'above_microsecond_wrap',
        4549534214400000,
        [_user(-4673868566400000), _user(ordinary)],
        '292278 years',
        '292278 年',
      ),
      ('single_user_has_no_older_user', ordinary, [_user(ordinary)], 'just now', 'just now'),
      ('selected_missing_date_stops_search', late, [_user(early), _user(null), assistant], 'just now', 'just now'),
      (
        'long_span_ignores_system_and_nonuser_tail',
        late,
        [
          _user(ordinary),
          _user(early),
          assistant,
          assistant,
          MacroMessage(
            text: 'system',
            isSystem: true,
            isUser: true,
            sentAt: DateTime.fromMillisecondsSinceEpoch(late, isUtc: true),
          ),
        ],
        '400000 years',
        '400000 年',
      ),
    ];
    for (final legacy in [false, true]) {
      for (final locale in ['en', 'zh-cn']) {
        for (final (id, epoch, history, en, zh) in rows) {
          final context = MacroContext(
            now: DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true),
            history: history,
            timeZoneOffset: Duration.zero,
            locale: locale,
            random: () => throw StateError('Unexpected random draw.'),
          );
          final expected = locale == 'en' ? en : zh;
          expect(_idle(context, legacy), 'LEFT${expected}RIGHT', reason: 'fixed ST: $id locale=$locale legacy=$legacy');
        }
      }
      // Local compatibility controls, not ST microsecond observations.
      // Both truncated differences have magnitude 44499ms, below the minute threshold.
      for (final (nowUs, sentAtUs) in [(44499000, -500), (-500, 44499000)]) {
        final context = MacroContext(
          now: DateTime.fromMicrosecondsSinceEpoch(nowUs, isUtc: true),
          history: [
            MacroMessage(
              text: 'anchor',
              isUser: true,
              sentAt: DateTime.fromMicrosecondsSinceEpoch(sentAtUs, isUtc: true),
            ),
            assistant,
          ],
          timeZoneOffset: Duration.zero,
          locale: 'en',
          random: () => throw StateError('Unexpected random draw.'),
        );
        expect(
          _idle(context, legacy),
          'LEFTa few secondsRIGHT',
          reason: 'existing Context: nowUs=$nowUs sentAtUs=$sentAtUs legacy=$legacy',
        );
      }
    }
  });

  test('modern sendOnly preserves long idleDuration spans through stored history and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-idle-span-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('IDLE_SPAN_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    var now = DateTime.utc(2024, 1, 1, 11, 57);
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'idle-span-oracle',
    );
    Future<TavernEngine> open() =>
        TavernEngine.openDirectory(root, config: config, modelClient: model, clock: () => now);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'locale': 'en', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect((greeting.role, greeting.text, greeting.parentId), (TavernRole.character, 'G', null));
    now = DateTime.utc(2024, 1, 1, 11, 58);
    final ordinaryAnchor = await facade.sendOnly(chatId, 'ORDINARY_ANCHOR');
    now = DateTime.utc(2024, 1, 1, 11, 59);
    final ordinaryTail = await facade.sendOnly(chatId, 'ORDINARY_TAIL');
    now = DateTime.utc(2024, 1, 1, 12);
    const input = 'LEFT{{idleDuration}}RIGHT';
    const ordinaryBody = 'LEFT2 minutesRIGHT';
    final ordinary = await facade.sendOnly(chatId, input);
    expect(ordinary.text, ordinaryBody);

    now = DateTime.utc(-200000, 1, 1);
    final anchor = await facade.sendOnly(chatId, 'ANCHOR');
    now = DateTime.utc(2024, 1, 1);
    final tail = await facade.sendOnly(chatId, 'TAIL');
    final beforeTarget = <(String, String?, TavernRole, String, int)>[
      (greeting.nodeId, null, TavernRole.character, 'G', 1704110220000),
      (ordinaryAnchor.nodeId, greeting.nodeId, TavernRole.user, 'ORDINARY_ANCHOR', 1704110280000),
      (ordinaryTail.nodeId, ordinaryAnchor.nodeId, TavernRole.user, 'ORDINARY_TAIL', 1704110340000),
      (ordinary.nodeId, ordinaryTail.nodeId, TavernRole.user, ordinaryBody, 1704110400000),
      (anchor.nodeId, ordinary.nodeId, TavernRole.user, 'ANCHOR', -6373557619200000),
      (tail.nodeId, anchor.nodeId, TavernRole.user, 'TAIL', 1704067200000),
    ];
    const beforeDates = [
      '2024-01-01T11:57:00.000Z',
      '2024-01-01T11:58:00.000Z',
      '2024-01-01T11:59:00.000Z',
      '2024-01-01T12:00:00.000Z',
      '-200000-01-01T00:00:00.000Z',
      '2024-01-01T00:00:00.000Z',
    ];
    Future<void> checkSaved(List<(String, String?, TavernRole, String, int)> expected, List<String> dates) async {
      final path = await facade.path(chatId);
      expect(
        path.map(
          (message) =>
              (message.nodeId, message.parentId, message.role, message.text, message.at.millisecondsSinceEpoch),
        ),
        expected,
      );
      expect(
        path.map((message) => (message.at.isUtc, message.at.toIso8601String())),
        dates.map((date) => (true, date)),
      );
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$4));
      expect(document.messages.map((message) => message['send_date']), dates);
      final settings = await facade.readSettings(chatId: chatId);
      expect(settings['macroEngine'], 'modern');
      expect(settings['locale'], 'en');
      expect(settings['globalRegexScripts'], isEmpty);
      expect(await facade.readVariables(chatId), isEmpty);
      expect(await facade.inspectTurn(chatId), isNull);
      expect(model.generated, 0);
      expect(keyReads, 0);
    }

    // Restore the negative-year anchor from real SQLite before the old core.
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(beforeTarget, beforeDates);
    now = DateTime.utc(200000, 1, 1);
    stdout.writeln('IDLE_SPAN_READY');
    final boundary = await facade.sendOnly(chatId, input);
    // First target assertion. Raw118 idle source predicts LEFT184554 yearsRIGHT;
    // this is not an idle Dart run or borrowed from the timeDiff runtime.
    const targetBody = 'LEFT400000 yearsRIGHT';
    expect(boundary.text, targetBody);
    final expected = [...beforeTarget, (boundary.nodeId, tail.nodeId, TavernRole.user, targetBody, 6249223180800000)];
    final dates = [...beforeDates, '+200000-01-01T00:00:00.000Z'];
    await checkSaved(expected, dates);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(expected, dates);
  });
}
