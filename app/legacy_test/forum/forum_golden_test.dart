// Goldens of the forum (light + dark): home, a topic, the new-topic composer,
// the sign-in sheet and notifications.
//
//   flutter test --update-goldens test/forum/forum_golden_test.dart

import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/ui/forum/forum_account_sheet.dart';
import 'package:dsh_app/ui/forum/forum_composer_sheet.dart';
import 'package:dsh_app/ui/forum/forum_home_page.dart';
import 'package:dsh_app/ui/forum/forum_notifications_page.dart';
import 'package:dsh_app/ui/forum/forum_topic_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../providers/support.dart' show settle;
import '../shell/golden_harness.dart';
import 'support.dart';

void main() {
  goldenBoth(
    'forum_home',
    () => const ForumHomePage(),
    overrides: () => forumOverrides(FakeForumApi(signedIn: true), auth: signedInAuth),
  );

  goldenBoth('forum_home_signed_out', () => const ForumHomePage(), overrides: () => forumOverrides(FakeForumApi()));

  goldenBoth(
    'forum_topic',
    () => const ForumTopicPage(topicId: 101),
    overrides: () => forumOverrides(FakeForumApi(signedIn: true), auth: signedInAuth),
  );

  goldenBoth(
    'forum_composer',
    () => _SheetHost(open: (context) => showForumComposer(context, const ForumNewTopicTarget())),
    overrides: () => forumOverrides(FakeForumApi(signedIn: true), auth: signedInAuth),
    before: (tester) async {
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), '手机上跑 DSH 的省电配置');
      await tester.tap(find.text('配置分享'));
      await tester.enterText(
        find.byType(TextField).at(1),
        '后台保活 + 低功耗模型，一晚上只掉 3% 电。\n\n[配置：省电模式](https://ccch1mneyyy.github.io/dsh-go/share/#p=…)',
      );
      await settle(tester);
      // The caret blinks: park focus so both themes freeze the same frame.
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);
    },
  );

  goldenBoth(
    'forum_sign_in',
    () => _SheetHost(open: showForumAccountSheet),
    overrides: () => forumOverrides(FakeForumApi()),
    before: (tester) async {
      await tester.tap(find.text('open'));
      await settle(tester);
    },
  );

  goldenBoth(
    'forum_account',
    () => _SheetHost(open: showForumAccountSheet),
    overrides: () => forumOverrides(
      FakeForumApi(
        signedIn: true,
        summary: const ForumUserSummary(topicCount: 12, postCount: 86, likesReceived: 1240, daysVisited: 37),
      ),
      auth: signedInAuth,
    ),
    before: (tester) async {
      await tester.tap(find.text('open'));
      await settle(tester);
    },
  );

  goldenBoth(
    'forum_notifications',
    () => const ForumNotificationsPage(),
    overrides: () =>
        forumOverrides(FakeForumApi(signedIn: true, notificationPage: sampleNotifications()), auth: signedInAuth),
  );
}

/// A blank page with a button that opens a sheet.
class _SheetHost extends StatelessWidget {
  const _SheetHost({required this.open});

  final Future<void> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: Center(
      child: TextButton(onPressed: () => open(context), child: const Text('open')),
    ),
  );
}
