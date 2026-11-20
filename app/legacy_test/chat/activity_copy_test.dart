// What the activity pill says next to its status: the `⏵` narration, the
// rotating copy (stable within a window, never repeating the previous one),
// and every easter egg's trigger (after-tool, milestones, holidays, weekend,
// night, rare, long turns), plus the live activity derived from chat state.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/activity_copy.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/run_info_fixture.dart';
import 'support/sample_chat.dart';

/// A weekday afternoon with no holiday (Tue 2026-10-20 15:00).
final weekday = DateTime(2026, 10, 20, 15);

RunActivity model(
  ActivityKind kind, {
  DateTime? since,
  DateTime? turnStart,
  String? narration,
  bool firstStep = false,
  AfterTool? after,
  int toolsDone = 0,
}) {
  final start = turnStart ?? weekday.subtract(const Duration(minutes: 1));
  return RunActivity(
    kind: kind,
    title: '思考中',
    since: since ?? weekday,
    turnStart: start,
    narration: narration,
    firstStep: firstStep,
    after: after,
    toolsDone: toolsDone,
  );
}

ActivityFlavor? flavorAt(RunActivity a, Duration into) => activityFlavor(a, a.since!.add(into));

/// A turn start whose seed does (or does not) draw the rare egg.
DateTime rareStart({required bool rare}) {
  var t = DateTime(2026, 10, 20, 14, 59);
  while (rareTurn(t) != rare) {
    t = t.add(const Duration(milliseconds: 1));
  }
  return t;
}

void main() {
  group('rotation', () {
    test('the hash matches working-activity (Math.imul port)', () {
      // Reference values from the TypeScript original under Node.
      expect(mixSlot(0, 0), 0);
      expect(mixSlot(1, 0), 839798425);
      expect(mixSlot(12345, 7), 79149362);
      expect(mixSlot(2147483647, 3), 3584545071);
      expect(mixSlot(1792720940000, 0), 2166939366);
      expect(mixSlot(4000000000, 5), 2523771890);
    });

    test('one phrase per window; adjacent windows differ', () {
      final a = model(ActivityKind.thinking, turnStart: rareStart(rare: false));
      final first = flavorAt(a, Duration.zero)!.text;
      expect(flavorAt(a, const Duration(milliseconds: 3999))!.text, first);
      for (var slot = 1; slot < 40; slot++) {
        final here = flavorAt(a, phraseWindow * slot)!.text;
        final before = flavorAt(a, phraseWindow * (slot - 1))!.text;
        expect(here, isNot(before), reason: 'slot $slot');
        // Past 28 s the long-thinking tiers take over (tested below).
        if (slot < 7) expect(thinkingPhrases, contains(here));
      }
    });

    test('pools follow the phase', () {
      final start = rareStart(rare: false);
      String at(ActivityKind kind) => flavorAt(model(kind, turnStart: start), phraseWindow * 3)!.text;
      expect(waitingPhrases, contains(at(ActivityKind.waiting)));
      expect(writingPhrases, contains(at(ActivityKind.writing)));
      expect(thinkingPhrases, contains(at(ActivityKind.thinking)));
      expect(compactionPhrases, contains(at(ActivityKind.compaction)));
      expect(retryPhrases, contains(at(ActivityKind.retry)));
      final limited = RunActivity(kind: ActivityKind.retry, title: '重试中', since: weekday, rateLimited: true);
      expect(rateLimitPhrases, contains(activityFlavor(limited, weekday)!.text));
    });

    test('tools and waiting on you carry their own detail, no copy', () {
      for (final kind in [ActivityKind.tool, ActivityKind.approval, ActivityKind.question]) {
        expect(flavorAt(model(kind), Duration.zero), isNull);
      }
    });

    test('long thinking moves to the tiers at the window start', () {
      final a = model(ActivityKind.thinking, turnStart: rareStart(rare: false));
      // 28–32 s: the window began at 28 s, before the 30 s tier.
      expect(thinkingPhrases, contains(flavorAt(a, const Duration(seconds: 31))!.text));
      expect(thinkingTiers[2].$2, contains(flavorAt(a, const Duration(seconds: 33))!.text));
      expect(thinkingTiers[1].$2, contains(flavorAt(a, const Duration(seconds: 61))!.text));
      expect(thinkingTiers[0].$2, contains(flavorAt(a, const Duration(minutes: 6))!.text));
    });

    test('after midnight the night copy is in the pool', () {
      Set<String> sample(DateTime start) {
        final seen = <String>{};
        // Keep the original 199 samples. Night copy only participates in the
        // first seven slots, before the long-thinking tiers take over.
        // Also sample a phase starting with its turn: equal timestamps give
        // a timezone-independent seed without changing the local day/night.
        for (final startsTurn in [false, true]) {
          final activity = RunActivity(
            kind: ActivityKind.thinking,
            title: '思考中',
            since: start,
            turnStart: startsTurn ? start : start.subtract(const Duration(minutes: 1)),
          );
          final slots = startsTurn ? 8 : 200;
          for (var slot = 1; slot < slots; slot++) {
            seen.add(activityFlavor(activity, start.add(phraseWindow * slot))!.text);
          }
        }
        return seen;
      }

      final night = sample(DateTime(2026, 10, 20, 2));
      expect(night.intersection(nightPhrases.toSet()), isNotEmpty);
      final day = sample(weekday);
      expect(day.intersection(nightPhrases.toSet()), isEmpty);
    });
  });

  group('narration', () {
    test('a ⏵ line at the start of a line, cut at the sentence end', () {
      expect(extractNarration('⏵ 修复登录页样式\n好的，我先看看'), '修复登录页样式');
      expect(extractNarration('先说明。\n⏵ 查一下报错原因。然后再改'), '查一下报错原因');
      expect(extractNarration('⏵ Fixing the login page. Then tests'), 'Fixing the login page');
      expect(extractNarration('⏵ 改 lib/main.dart 的入口'), '改 lib/main.dart 的入口');
      expect(extractNarration('格式是 ⏵ 加一句话'), isNull, reason: 'mid-line');
      expect(extractNarration('⏵   \n正文'), isNull);
      expect(extractNarration('⏵ 第一件\n…\n⏵ 第二件'), '第二件');
    });

    test('cut to 40 Chinese characters, at a comma when there is one', () {
      final long = '⏵ ${'很' * 30}，${'长' * 30}';
      expect(extractNarration(long), '很' * 30);
      expect(extractNarration('⏵ ${'长' * 50}')!.length, 40);
    });

    test('only a document start or LF starts a marked line', () {
      for (final prefix in ['', '\n', '正文\r\n']) {
        expect(extractNarration('$prefix⏵ 更新状态'), '更新状态');
      }
      for (final prefix in [' ', '\t', '\r', '\u2028', '\n ', '正文']) {
        expect(extractNarration('$prefix⏵ 仅是正文'), isNull, reason: 'prefix ${prefix.codeUnits}');
      }
      expect(extractNarration('⏵ 当前状态\n正文里 ⏵ 不是新状态'), '当前状态');
    });

    test('an empty latest marked line clears the earlier narration', () {
      for (final tail in ['', ' ', '\t\r', '\u0000\u007f', '\u00a0', '⏵ 忽略同一行的第二个标记']) {
        expect(extractNarration('⏵ 旧状态\n正文\n⏵$tail'), isNull, reason: 'tail ${tail.codeUnits}');
      }
    });

    test('a marked line stops at LF or the next marker and strips controls', () {
      expect(extractNarration('⏵\t  第一项⏵第二项\n正文'), '第一项');
      expect(extractNarration('⏵ 旧项\r\n⏵\t 新\u0000状\t态\u007f\r\n正文'), '新状态');
      expect(extractNarration('⏵ 修复\u00a0页面\u00a0'), '修复\u00a0页面');
    });

    test('streamed text keeps the current narration until a new marked line', () {
      var text = '⏵ 当前状态\n';
      for (final unit in '持续输出正文，含行内 ⏵ 格式说明\n'.codeUnits) {
        text += String.fromCharCode(unit);
        expect(extractNarration(text), '当前状态');
      }
      text += '⏵';
      expect(extractNarration(text), isNull);
      text += ' ';
      expect(extractNarration(text), isNull);
      text += '新';
      expect(extractNarration(text), '新');
      text += '状态。后续正文';
      expect(extractNarration(text), '新状态');
    });

    test('keeps sentence, path, and display-column boundaries', () {
      expect(extractNarration('⏵ Read lib/main.dart. Then continue'), 'Read lib/main.dart');
      expect(extractNarration('⏵ Done.Next step'), 'Done');
      expect(extractNarration('⏵ Really? Then continue'), 'Really?');
      expect(extractNarration('⏵ ${'a' * 79}😀'), 'a' * 79);
      expect(extractNarration('⏵ ${'😀' * 41}'), '😀' * 40);
      expect(extractNarration('⏵ ${'a' * 70} ${'b' * 20}'), 'a' * 70);
    });

    test('selects the last marked line in a long reply', () {
      final body = '正文里提及 ⏵ 格式但不改变状态\n' * 6000;
      expect(extractNarration(body), isNull);
      expect(extractNarration('⏵ 初始状态\n$body'), '初始状态');
      expect(extractNarration('⏵ 初始状态\n$body⏵ 最新状态\n正文'), '最新状态');
      expect(extractNarration('${'⏵ 旧状态\n' * 6000}⏵ 最后状态'), '最后状态');
    });

    test('the latest reply of the turn decides; a reply without one clears it', () {
      expect(narrationOf([user(1, '修一下'), assistant(2, '⏵ 看看登录页\n先读文件')]), '看看登录页');
      expect(narrationOf([user(1, '修一下'), assistant(2, '⏵ 看看登录页\n先读文件'), assistant(3, '找到了，原因是……')]), isNull);
      expect(narrationOf([assistant(1, '⏵ 上一轮的事'), user(2, '新问题')]), isNull);
    });

    test('narration wins over copy and eggs', () {
      final a = model(
        ActivityKind.writing,
        narration: '修复登录页样式',
        after: (name: 'bash', command: 'flutter test', failed: true),
      );
      final flavor = flavorAt(a, Duration.zero)!;
      expect(flavor.text, '修复登录页样式');
      expect(flavor.source, FlavorSource.narration);
    });
  });

  group('easter eggs', () {
    AfterTool bash(String command, {bool failed = false}) => (name: 'bash', command: command, failed: failed);

    test('after a tool: failure, tests green / red, git, installs', () {
      String? first(AfterTool after) {
        final f = flavorAt(model(ActivityKind.thinking, after: after), Duration.zero);
        return f?.source == FlavorSource.egg ? f!.text : null;
      }

      expect(failPhrases, contains(first(bash('ls /nope', failed: true))));
      expect(failPhrases, contains(first((name: 'read', command: null, failed: true))));
      expect(testPassPhrases, contains(first(bash('flutter test test/auth'))));
      expect(testFailPhrases, contains(first(bash('npm test', failed: true))));
      expect(gitPushPhrases, contains(first(bash('git push origin main'))));
      expect(gitCommitPhrases, contains(first(bash('git commit -m "fix"'))));
      expect(installPhrases, contains(first(bash('flutter pub get'))));
      expect(first(bash('ls -la')), isNull);
      expect(first((name: 'read', command: null, failed: false)), isNull);
    });

    test('only in the first window of the phase', () {
      final a = model(ActivityKind.thinking, after: bash('flutter test'), turnStart: rareStart(rare: false));
      expect(testPassPhrases, contains(flavorAt(a, const Duration(seconds: 3))!.text));
      expect(testPassPhrases, isNot(contains(flavorAt(a, const Duration(seconds: 5))!.text)));
    });

    test('tool milestones: the 5th, 10th, 20th, 50th call of the turn', () {
      String? at(int done) =>
          flavorAt(model(ActivityKind.thinking, after: bash('ls'), toolsDone: done), Duration.zero)!.text;
      expect(at(5), '工具 x5，手感来了');
      expect(at(10), '工具连击 x10');
      expect(at(50), '工具 x50，劳模本模');
      expect(toolMilestones.values, isNot(contains(at(6))));
    });

    test('holidays: 1024, fixed dates, Lunar New Year with its zodiac', () {
      expect(holidayPool(DateTime(2026, 10, 24)), holidayPhrases['10-24']);
      expect(holidayPool(DateTime(2026, 12, 25)), holidayPhrases['12-25']);
      expect(holidayPool(DateTime(2026, 10, 20)), isNull);
      expect(holidayPool(DateTime(2026, 2, 17)), contains('马年大吉'));
      expect(holidayPool(DateTime(2026, 2, 23, 23)), contains('马年大吉'));
      expect(holidayPool(DateTime(2026, 2, 24)), isNull);
      expect(holidayPool(DateTime(2027, 2, 8)), contains('羊年大吉'));
    });

    test('the Lunar New Year table still covers next year', () {
      final next = DateTime.now().year + 1;
      expect(lunarNewYearDays.any((d) => d.startsWith('$next-')), isTrue, reason: 'add next year to lunarNewYearDays');
    });

    test('date eggs open the first request of a turn, in its first window', () {
      final programmersDay = DateTime(2026, 10, 24, 15); // a Saturday too
      RunActivity at(DateTime now, {bool firstStep = true}) =>
          RunActivity(kind: ActivityKind.thinking, title: '思考中', since: now, turnStart: now, firstStep: firstStep);
      final egg = activityFlavor(at(programmersDay), programmersDay)!;
      expect(egg.source, FlavorSource.egg);
      expect(holidayPhrases['10-24'], contains(egg.text));
      expect(activityFlavor(at(programmersDay), programmersDay.add(phraseWindow))!.source, FlavorSource.phrase);
      expect(activityFlavor(at(programmersDay, firstStep: false), programmersDay)!.source, FlavorSource.phrase);

      final sunday = DateTime(2026, 10, 25, 15);
      var start = sunday;
      while (rareTurn(start)) {
        start = start.add(const Duration(milliseconds: 1));
      }
      expect(weekendPhrases, contains(activityFlavor(at(start), start)!.text));
    });

    test('rare: decided by the turn, about 1 in 150, for the whole request', () {
      var hits = 0;
      final base = DateTime(2026, 10, 20, 14);
      for (var i = 0; i < 30000; i++) {
        if (rareTurn(base.add(Duration(milliseconds: i * 37)))) hits++;
      }
      expect(hits / 30000, closeTo(1 / 150, 0.002));

      final start = rareStart(rare: true);
      final a = RunActivity(kind: ActivityKind.thinking, title: '思考中', since: start, turnStart: start, firstStep: true);
      for (final into in [Duration.zero, phraseWindow * 5]) {
        final f = activityFlavor(a, start.add(into))!;
        expect(rarePhrases, contains(f.text));
        expect(f.source, FlavorSource.egg);
      }
      final later = RunActivity(kind: ActivityKind.thinking, title: '思考中', since: start, turnStart: start);
      expect(rarePhrases, isNot(contains(activityFlavor(later, start)!.text)));
    });

    test('long turns: 10 min, 30 min, every hour, each for 8 s', () {
      expect(longTurnReminder(const Duration(minutes: 9)), isNull);
      expect(longTurnReminder(const Duration(minutes: 10)), '10 分钟了，这活不小');
      expect(longTurnReminder(const Duration(minutes: 10, seconds: 7)), isNotNull);
      expect(longTurnReminder(const Duration(minutes: 10, seconds: 8)), isNull);
      expect(longTurnReminder(const Duration(minutes: 30)), '半小时了，喝口水？');
      expect(longTurnReminder(const Duration(hours: 2)), '已经连续干了 2 小时，歇会儿？');
      expect(longTurnReminder(const Duration(hours: 2, minutes: 10)), isNull);

      final start = rareStart(rare: false);
      final a = RunActivity(
        kind: ActivityKind.thinking,
        title: '思考中',
        since: start.add(const Duration(minutes: 29, seconds: 50)),
        turnStart: start,
      );
      expect(activityFlavor(a, start.add(const Duration(minutes: 30, seconds: 2))), (
        text: '半小时了，喝口水？',
        source: FlavorSource.egg,
      ));
    });
  });

  group('live activity', () {
    test('a running command: short verb, its target, turn clock', () {
      final s = runInfoState();
      final a = runActivityOf(s)!;
      expect(a.kind, ActivityKind.tool);
      expect(a.title, '跑');
      expect(a.detail, 'flutter test');
      expect(a.detailIsCode, isTrue);
      expect(a.since, runInfoTestDispatched);
      expect(a.turnStart, runInfoTurnTwoStart);
      expect(a.narration, isNull, reason: 'tools have their own detail');
    });

    test('streaming: waiting for the first token, reasoning, writing', () {
      ChatState draft({String text = '', String reasoning = ''}) => ChatState(
        running: true,
        items: [
          user(1, 'hi'),
          assistant(2, text, reasoning: reasoning, streaming: true),
        ],
      );
      expect(runActivityOf(draft())!.kind, ActivityKind.waiting);
      expect(runActivityOf(draft())!.title, '思考中');
      final thinking = runActivityOf(draft(reasoning: '嗯'))!;
      expect((thinking.kind, thinking.title), (ActivityKind.thinking, '思考中'));
      final writing = runActivityOf(draft(text: '⏵ 解释一下\n好的'))!;
      expect((writing.kind, writing.title), (ActivityKind.writing, '写回复中'));
      expect(writing.narration, '解释一下');
    });

    test('the request after a tool knows which tool it was', () {
      // Turn 1 cut after step 1 (read, then grep): step 2 is being asked.
      final t = runInfoTranscript(throughSeq: 12);
      final s = ChatState(items: t.items, running: true, turns: t.turns, todos: t.todos);
      final a = runActivityOf(s)!;
      expect(a.kind, ActivityKind.waiting);
      expect(a.after, (name: 'grep', command: null, failed: false));
      expect(a.firstStep, isFalse);
      expect(a.toolsDone, 2);
    });

    test('compaction reads as its own state', () {
      final a = compactionActivity(runInfoState(), runInfoTestDispatched);
      expect(a.kind, ActivityKind.compaction);
      expect(a.title, '压缩上下文');
      expect(a.turnStart, runInfoTurnTwoStart);
    });
  });
}
