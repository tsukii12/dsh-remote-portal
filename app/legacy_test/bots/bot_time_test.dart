import 'package:dsh_app/ui/bots/bot_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late DateTime Function() previousClock;
  setUp(() => previousClock = botClock);
  tearDown(() => botClock = previousClock);

  test('Bot fixtures and timestamps share the frozen calendar day', () {
    for (final day in [DateTime(2001, 12, 31, 18), DateTime(2002, 1, 1, 18), DateTime(2028, 2, 29, 18)]) {
      botClock = () => day;
      expect(todayAt(9, 41), DateTime(day.year, day.month, day.day, 9, 41));
      expect(shortTime(todayAt(9, 41)), '09:41');
      final chat = sampleChat().first as Map<String, Object?>;
      final room = sampleRoomItems().first as Map<String, Object?>;
      expect(shortTime(DateTime.fromMillisecondsSinceEpoch(chat['time']! as int)), '14:02');
      expect(shortTime(DateTime.fromMillisecondsSinceEpoch(room['time']! as int)), '15:10');
      final work = liveOf({})['work']! as Map<String, Object?>;
      final bots = work['bots']! as Map<String, Object?>;
      final main = bots['m1']! as Map<String, Object?>;
      expect(main['since'], day.millisecondsSinceEpoch - 40000);
    }
  });

  test('the default clock keeps the strict past and future just-now boundary', () {
    final message = DateTime(2001, 12, 31, 15, 10);
    for (final (seconds, label) in [(-60, '15:10'), (-59, '刚刚'), (0, '刚刚'), (59, '刚刚'), (60, '15:10')]) {
      botClock = () => message.add(Duration(seconds: seconds));
      expect(shortTime(message), label, reason: '$seconds seconds from the message');
    }
  });

  test('calendar labels still cross midnight and the year boundary', () {
    botClock = () => DateTime(2002, 1, 1, 12);
    expect(shortTime(DateTime(2002, 1, 1, 9, 5)), '09:05');
    expect(shortTime(DateTime(2001, 12, 31, 9, 5)), '昨天');
    expect(shortTime(DateTime(2001, 12, 30, 9, 5)), '2001/12/30');
    botClock = () => DateTime(2002, 10, 24, 12);
    expect(shortTime(DateTime(2002, 3, 2)), '3月2日');
  });

  test('explicit now and absent timestamps do not consult the default clock', () {
    botClock = () => throw StateError('the default clock must not be read');
    expect(shortTime(null), '');
    expect(shortTime(DateTime(2001, 12, 31, 15, 10), now: DateTime(2001, 12, 31, 18)), '15:10');
  });
}
