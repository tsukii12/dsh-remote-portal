// Run with TZ=America/New_York to exercise real 23/25-hour local days:
// TZ=America/New_York flutter test test/drawer/drawer_calendar_test.dart
import 'dart:io';

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the requested New York timezone has real spring and autumn transitions', () {
    final springHours = DateTime(2026, 3, 9).difference(DateTime(2026, 3, 8)).inHours;
    final autumnHours = DateTime(2026, 11, 2).difference(DateTime(2026, 11, 1)).inHours;
    // These checks fail, rather than skip, if an explicitly requested DST
    // process does not use its timezone. Ordinary CI can also run this file.
    if (Platform.environment['TZ'] == 'America/New_York') {
      expect(springHours, 23);
      expect(autumnHours, 25);
    }
    // ignore: avoid_print
    print('TZ=${Platform.environment['TZ']} springHours=$springHours autumnHours=$autumnHours');
  });

  test('the day before spring Monday is yesterday', () {
    expect(sessionDayOf(DateTime(2026, 3, 8, 12), DateTime(2026, 3, 9, 12)), SessionDay.yesterday);
  });

  test('Saturday before spring Monday is earlier, not yesterday', () {
    expect(sessionDayOf(DateTime(2026, 3, 7, 12), DateTime(2026, 3, 9, 12)), SessionDay.earlier);
  });

  test('UTC session instants are grouped by their local calendar date', () {
    final at = DateTime(2026, 3, 8, 23, 30).toUtc();
    expect(sessionDayOf(at, DateTime(2026, 3, 9, 0, 30)), SessionDay.yesterday);
  });

  test('autumn Monday still treats Sunday as yesterday and Saturday as earlier', () {
    final now = DateTime(2026, 11, 2, 12);
    expect(sessionDayOf(DateTime(2026, 11, 1, 12), now), SessionDay.yesterday);
    expect(sessionDayOf(DateTime(2026, 10, 31, 12), now), SessionDay.earlier);
  });

  test('same day and future dates retain today grouping', () {
    final now = DateTime(2026, 3, 9, 12);
    expect(sessionDayOf(DateTime(2026, 3, 9, 0, 1), now), SessionDay.today);
    expect(sessionDayOf(DateTime(2026, 3, 10, 12), now), SessionDay.today);
  });

  test('ordinary days and month and year boundaries retain yesterday grouping', () {
    for (final now in [DateTime(2026, 3, 5, 12), DateTime(2026, 4, 1, 12), DateTime(2027, 1, 1, 12)]) {
      expect(sessionDayOf(DateTime(now.year, now.month, now.day - 1, 12), now), SessionDay.yesterday);
    }
  });

  test('Monday remains the first day of the week after spring transition', () {
    final now = DateTime(2026, 3, 11, 12);
    expect(sessionDayOf(DateTime(2026, 3, 10, 12), now), SessionDay.yesterday);
    expect(sessionDayOf(DateTime(2026, 3, 9, 12), now), SessionDay.thisWeek);
    expect(sessionDayOf(DateTime(2026, 3, 8, 12), now), SessionDay.earlier);
  });

  for (final sort in DrawerSort.values) {
    test('drawerBlocks uses calendar groups for ${sort.name} sorting across spring transition', () {
      final at = DateTime(2026, 3, 8, 23, 30).toUtc();
      final blocks = drawerBlocks(
        sessions: [
          SessionSummary.fromJson({
            'sessionId': 'yesterday',
            'updatedAt': (sort == DrawerSort.activity ? at : DateTime(2026, 3, 9, 10)).millisecondsSinceEpoch,
            'running': false,
            'blank': false,
            'agentAvailable': false,
          }),
        ],
        pinnedIds: const [],
        view: DrawerView(loaded: true, sort: sort),
        filter: DrawerFilter.all,
        pending: const {},
        unread: const {},
        createdAt: {'yesterday': at},
        now: DateTime(2026, 3, 9, 12),
      );
      expect(blocks, hasLength(1));
      final day = blocks.single as DayBlock;
      expect(day.day, SessionDay.yesterday);
      expect(day.items.single.sessionId, 'yesterday');
    });
  }
}
