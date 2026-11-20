import 'dart:async';

import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/forum/forum_notifications_page.dart';
import 'package:dsh_app/ui/forum/forum_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show loadTestFonts, pumpFrames, usePhoneView;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _NotificationsApi extends FakeForumApi {
  _NotificationsApi() : super(signedIn: true);

  final items = sampleNotifications().notifications;
  final offsets = <int>[];
  Object? moreFailure;
  Object? refreshFailure;
  Completer<ForumNotificationPage>? pendingRefresh;

  @override
  Future<ForumNotificationPage> notifications({int offset = 0}) async {
    offsets.add(offset);
    if (offset == 0) {
      if (pendingRefresh case final pending?) return pending.future;
      if (refreshFailure case final error?) throw error;
      return ForumNotificationPage(notifications: items.take(2).toList(), hasMore: true);
    }
    if (moreFailure case final error?) throw error;
    // Deliberately repeats the last row of page one to keep deduplication covered.
    return ForumNotificationPage(notifications: items.skip(1).toList());
  }
}

Future<ProviderContainer> _open(WidgetTester tester, _NotificationsApi api) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const ForumNotificationsPage(),
      brightness: Brightness.light,
      overrides: forumOverrides(api, auth: signedInAuth),
    ),
  );
  await pumpFrames(tester, 10);
  return ProviderScope.containerOf(tester.element(find.byType(ForumNotificationsPage)));
}

void _nearEnd(WidgetTester tester) {
  // Exercise the production scroll listener without depending on a device's
  // overscroll physics when the short fixture fits on screen.
  ScrollUpdateNotification(
    metrics: FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 300,
      pixels: 250,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    ),
    context: tester.element(find.byType(ForumNotificationRow).first),
    scrollDelta: 10,
  ).dispatch(tester.element(find.byType(ForumNotificationRow).first));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final typed in [true, false]) {
    testWidgets('pagination ${typed ? 'forum' : 'unexpected'} failure keeps rows and waits for explicit retry', (
      tester,
    ) async {
      final api = _NotificationsApi()
        ..moreFailure = typed ? const ForumException(ForumErrorKind.network) : StateError('SYNTHETIC paging');
      final container = await _open(tester, api);
      expect(api.offsets, [0]);
      _nearEnd(tester);
      await pumpFrames(tester, 10);
      final message = typed
          ? const ForumException(ForumErrorKind.network).message
          : appL10n.remoteForumErrNotifications;
      expect(find.text(appL10n.remoteForumErrorRetry(message)), findsOneWidget);
      expect(container.read(forumNotificationsProvider).value!.items, hasLength(2));
      expect(tester.widget<ForumListFooter>(find.byType(ForumListFooter)).loading, isFalse);

      for (var i = 0; i < 4; i++) {
        _nearEnd(tester);
        await tester.pump();
      }
      expect(api.offsets, [0, 2]);
      final controller = container.read(forumNotificationsProvider.notifier);
      await controller.markRead(api.items.first);
      await controller.markAllRead();
      await pumpFrames(tester, 4);
      expect(find.text(appL10n.remoteForumErrorRetry(message)), findsOneWidget);
      expect(container.read(forumNotificationsProvider).value!.unread, 0);
      _nearEnd(tester);
      await tester.pump();
      expect(api.offsets, [0, 2]);

      api.moreFailure = null;
      await tester.tap(find.text(appL10n.remoteForumErrorRetry(message)));
      await pumpFrames(tester, 10);
      expect(api.offsets, [0, 2, 2]);
      final data = container.read(forumNotificationsProvider).value!;
      expect(data.items.map((item) => item.id), api.items.map((item) => item.id));
      expect(data.hasMore, isFalse);
      expect(find.text(appL10n.remoteForumErrorRetry(message)), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('refresh failure reports an error notice and preserves the old notifications', (tester) async {
    final api = _NotificationsApi();
    final container = await _open(tester, api);
    api.refreshFailure = StateError('SYNTHETIC refresh');
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await pumpFrames(tester, 6);
    expect(container.read(forumNotificationsProvider).value!.items, hasLength(2));
    expect(find.text(appL10n.remoteForumErrNotifications), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh failure after the page leaves does not read a disposed ref', (tester) async {
    final api = _NotificationsApi();
    await _open(tester, api);
    api.pendingRefresh = Completer<ForumNotificationPage>();
    final done = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pumpWidget(const SizedBox());
    api.pendingRefresh!.completeError(StateError('SYNTHETIC late refresh'));
    await done;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsNothing);
  });
}
