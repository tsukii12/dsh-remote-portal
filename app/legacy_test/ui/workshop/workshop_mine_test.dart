import 'dart:async';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/workshop_submissions_state.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/workshop/workshop_mine.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_page.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart' show testTheme, usePhoneView;
import '../../workshop/support.dart' show workshopCaps;
import 'workshop_mine_support.dart';

const _lost = WorkshopException('workshop_timeout', resultUnknown: true);

Widget _page() => const Scaffold(body: CustomScrollView(slivers: [WorkshopMineSliver()]));

Future<ProviderContainer> _open(WidgetTester tester, WorkshopPageWorld world) async {
  await tester.pumpWidget(world.app(_page()));
  await settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(WorkshopMineSliver)));
}

Future<void> _openDetail(WidgetTester tester) async {
  await tester.tap(find.byType(WorkshopSubmissionRow).first);
  await settle(tester);
  expect(find.text(zh.workshopMineDetailTitle), findsOneWidget);
}

/// Opens the reason field, types [reason] and presses 继续.
Future<void> _askWithdraw(WidgetTester tester, String reason) async {
  await tester.tap(find.text(zh.workshopMineWithdraw));
  await settle(tester);
  if (reason.isNotEmpty) await tester.enterText(find.byType(TextField), reason);
  await tester.tap(find.text(zh.commonContinue));
  await settle(tester);
}

void main() {
  testWidgets('没登录：说明投稿记在账号上，给出登录，不去读列表', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld(account: authSignedOut);
    await _open(tester, world);

    expect(find.text(zh.workshopMineSignInTitle), findsOneWidget);
    expect(find.text(zh.workshopSignInTitle), findsOneWidget);
    expect(find.text(zh.workshopMinePublish), findsNothing);
    expect(world.client.pages, isEmpty);
    expectNoCodes(tester);

    // 登录走 GitHub 的设备码弹层。
    await tester.tap(find.text(zh.workshopSignInTitle));
    await settle(tester);
    expect(world.accountController.signInStarts, 1);
    expect(find.text('TEST-CODE'), findsOneWidget);
  });

  testWidgets('还没同意交出凭据：先看说明，同意的是说明里那一对来源，之后才读列表', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld(consent: false)
      ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    await _open(tester, world);

    expect(find.text(zh.workshopMineConsentTitle), findsOneWidget);
    expect(world.client.pages, isEmpty);
    expectNoCodes(tester);

    await tester.tap(find.text(zh.workshopMineConsentAction));
    await settle(tester);
    expect(find.text(zh.workshopDisclosureTitle), findsOneWidget);
    expect(find.text('workshop.example'), findsOneWidget);
    expect(find.text('github.com'), findsOneWidget);
    expect(world.preferences.writes, 0);

    // 「暂不」什么都不记。
    await tester.tap(find.text(zh.workshopDisclosureDecline));
    await settle(tester);
    expect(world.preferences.writes, 0);
    expect(world.client.pages, isEmpty);

    await tester.tap(find.text(zh.workshopMineConsentAction));
    await settle(tester);
    await tester.tap(find.text(zh.workshopDisclosureAccept));
    await settle(tester);
    expect(world.preferences.writes, 1);
    expect(world.client.pages, hasLength(1));
    expect(find.text('小猫'), findsOneWidget);
  });

  testWidgets('同意了但没能记在本机：照样读列表，并说明下次可能再问', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld(consent: false)
      ..preferences.writeDisclosure = (worker, account) async => throw StateError('disk');
    await _open(tester, world);

    await tester.tap(find.text(zh.workshopMineConsentAction));
    await settle(tester);
    await tester.tap(find.text(zh.workshopDisclosureAccept));
    await tester.pump();
    await tester.pump();
    expect(find.text(zh.workshopDisclosureUnsaved), findsOneWidget);
    await settle(tester);
    expect(world.client.pages, hasLength(1));
    expectNoCodes(tester);
  });

  testWidgets('工坊的检查没过：一句人话加重试，重试后读出列表', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readCapabilities = () async => throw const WorkshopException('workshop_network');
    await _open(tester, world);

    expect(find.text(zh.workshopUnavailableTitle), findsOneWidget);
    expect(find.text(zh.workshopErrorNetwork), findsOneWidget);
    expect(world.client.pages, isEmpty);
    expectNoCodes(tester);

    world.client.readCapabilities = null;
    await tester.tap(find.text(zh.commonRetry));
    await settle(tester);
    expect(world.client.pages, hasLength(1));
    expect(find.text(zh.workshopMineEmptyTitle), findsOneWidget);
  });

  testWidgets('列表：每行是名称、种类和版本、状态；顶上一个投稿入口和状态筛选', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([
        personalRow(),
        personalRow(id: personalSecondId, status: WorkshopSubmissionStatus.rejected),
        personalRow(id: personalThirdId, status: WorkshopSubmissionStatus.withdrawn),
      ], null);
    await _open(tester, world);

    expect(find.byType(WorkshopSubmissionRow), findsNWidgets(3));
    expect(find.text('小猫'), findsNWidgets(3));
    expect(find.text('${zh.workshopKindPet} · 1.0.0'), findsNWidgets(3));
    final chips = tester.widgetList<StatusChip>(find.byType(StatusChip)).map((chip) => chip.label).toList();
    expect(chips, [zh.workshopMineStatusPending, zh.workshopMineStatusRejected, zh.workshopMineStatusWithdrawn]);
    // 一个投稿入口，没有第二个实心按钮。
    expect(find.text(zh.workshopMinePublish), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text(zh.workshopKindAll), findsOneWidget);
    expect(find.text(zh.workshopMineLoadMore), findsNothing);
    expectNoCodes(tester);
  });

  testWidgets('一条都没有：空状态带投稿；投稿页回来后重新读列表', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    await _open(tester, world);

    expect(find.text(zh.workshopMineEmptyTitle), findsOneWidget);
    // 空状态自己带投稿，顶上不再放一个。
    expect(find.text(zh.workshopMinePublish), findsOneWidget);
    expect(find.text(zh.workshopKindAll), findsNothing);
    expect(world.client.pages, hasLength(1));

    await tester.tap(find.text(zh.workshopMinePublish));
    await settle(tester);
    expect(find.byType(WorkshopPublishPage), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
    expect(find.byType(WorkshopPublishPage), findsNothing);
    expect(world.client.pages, hasLength(2));
  });

  testWidgets('工坊暂停收稿：投稿入口换成一句说明，列表照常能看', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    world.client
      ..value = WorkshopCapabilities.fromJson(workshopCaps(account: authAccount.toString(), uploads: false))
      ..readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    await _open(tester, world);

    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
    expect(find.text(zh.workshopErrorUploadOff), findsOneWidget);
    expect(find.text(zh.workshopMinePublish), findsNothing);
  });

  testWidgets('第一次就没读到：空状态里一句人话加重试，重试后出列表', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) async => throw const WorkshopException('workshop_network');
    await _open(tester, world);

    expect(find.text(zh.workshopMineLoadFailed), findsOneWidget);
    expect(find.text(zh.workshopErrorNetwork), findsOneWidget);
    expect(find.byType(WorkshopSubmissionRow), findsNothing);
    expectNoCodes(tester);

    world.client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    await tester.tap(find.text(zh.commonRetry));
    await settle(tester);
    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
    expect(find.text(zh.workshopMineLoadFailed), findsNothing);
  });

  testWidgets('刷新失败：旧的行留着，上面一句说明加重试', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    final container = await _open(tester, world);

    world.client.readPage = (cursor, status) async => throw const WorkshopException('workshop_rate_limited');
    await container.read(workshopSubmissionsProvider.notifier).refresh();
    await settle(tester);

    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
    expect(find.text('${zh.workshopMineStale} ${zh.workshopErrorRateLimited}'), findsOneWidget);
    expect(find.text(zh.commonRetry), findsOneWidget);
    expectNoCodes(tester);

    world.client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    await tester.tap(find.text(zh.commonRetry));
    await settle(tester);
    expect(find.textContaining(zh.workshopMineStale), findsNothing);
  });

  testWidgets('加载更多：接上下一页，没有下一页就收起；忙的时候别的操作只给一句提示', (tester) async {
    usePhoneView(tester);
    final second = Completer<WorkshopSubmissionPage>();
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) =>
          cursor == null ? Future.value(WorkshopSubmissionPage([personalRow()], personalFirstId)) : second.future;
    await _open(tester, world);

    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
    await tester.tap(find.text(zh.workshopMineLoadMore));
    await tester.pump();
    // 下一页在路上：按钮让位给一个小环，筛选不被接纳。
    expect(find.text(zh.workshopMineLoadMore), findsNothing);
    await tester.tap(find.text(zh.workshopMineStatusRejected));
    await tester.pump();
    await tester.pump();
    expect(find.text(zh.workshopErrorBusy), findsOneWidget);
    expect(world.client.pages, hasLength(2));

    second.complete(WorkshopSubmissionPage([personalRow(id: personalSecondId)], null));
    await settle(tester);
    expect(find.byType(WorkshopSubmissionRow), findsNWidgets(2));
    expect(find.text(zh.workshopMineLoadMore), findsNothing);
    expect(world.client.pages.last.cursor, personalFirstId);
  });

  testWidgets('按状态筛选：只请求那个状态；没有就说没有这类投稿，投稿入口还在', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) async =>
          WorkshopSubmissionPage(status == null ? [personalRow()] : const [], null);
    await _open(tester, world);

    await tester.tap(find.text(zh.workshopMineStatusRejected));
    await settle(tester);
    expect(world.client.pages.last.status, WorkshopSubmissionStatus.rejected);
    expect(find.text(zh.workshopMineEmptyFiltered), findsOneWidget);
    expect(find.byType(WorkshopSubmissionRow), findsNothing);
    expect(find.text(zh.workshopMinePublish), findsOneWidget);

    await tester.tap(find.text(zh.workshopKindAll));
    await settle(tester);
    expect(world.client.pages.last.status, isNull);
    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
  });

  testWidgets('换了账号：上一个账号的行立刻不见，新账号的读到了才出现', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
    await _open(tester, world);
    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);

    final next = Completer<WorkshopSubmissionPage>();
    world.client.readPage = (cursor, status) => next.future;
    world.accountController.emit(
      authSignedIn(
        credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'),
        userId: 43,
      ),
    );
    await settle(tester, 4);
    expect(find.byType(WorkshopSubmissionRow), findsNothing);
    expect(find.text('小猫'), findsNothing);

    next.complete(WorkshopSubmissionPage([personalRow(id: personalSecondId, userId: 43)], null));
    await settle(tester);
    expect(find.byType(WorkshopSubmissionRow), findsOneWidget);
  });

  testWidgets('下拉刷新的入口：能读就重读一遍；没登录、读失败都不抛', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    late WidgetRef pageRef;
    await tester.pumpWidget(
      world.app(
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              pageRef = ref;
              return const CustomScrollView(slivers: [WorkshopMineSliver()]);
            },
          ),
        ),
      ),
    );
    await settle(tester);
    expect(world.client.pages, hasLength(1));

    await refreshWorkshopMine(pageRef);
    expect(world.client.pages, hasLength(2));

    world.client.readPage = (cursor, status) async => throw StateError('boom');
    await refreshWorkshopMine(pageRef);
    expect(world.client.pages, hasLength(3));
    await settle(tester);
    expectNoCodes(tester);

    world.accountController.emit(authSignedOut);
    await settle(tester, 4);
    await refreshWorkshopMine(pageRef);
    expect(world.client.pages, hasLength(3));
  });

  group('单条详情', () {
    testWidgets('被拒绝的：状态一句话、审核意见、两个时间，可以撤回', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async =>
            WorkshopSubmissionPage([personalRow(status: WorkshopSubmissionStatus.rejected)], null);
      await _open(tester, world);
      await _openDetail(tester);

      expect(find.text(zh.workshopMineAboutRejected), findsOneWidget);
      expect(find.text(zh.workshopMineReviewReason), findsOneWidget);
      expect(find.text('review reason'), findsOneWidget);
      expect(find.text(zh.workshopMineCreatedAt), findsOneWidget);
      expect(find.text(zh.workshopMineUpdatedAt), findsOneWidget);
      expect(find.text(zh.workshopMineWithdraw), findsOneWidget);
      expectNoCodes(tester);
    });

    testWidgets('已撤回的：写着撤回原因，不再给撤回', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async =>
            WorkshopSubmissionPage([personalRow(status: WorkshopSubmissionStatus.withdrawn)], null);
      await _open(tester, world);
      await _openDetail(tester);

      expect(find.text(zh.workshopMineAboutWithdrawn), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawReason), findsOneWidget);
      expect(find.text('author withdrew'), findsOneWidget);
      expect(find.text(zh.workshopMineWithdraw), findsNothing);
    });

    testWidgets('刷新这一条：只重读这一条，读到的新状态马上显示，列表里那行也跟着变', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
        ..client.readSubmission = (id) async => personalRow(id: id, status: WorkshopSubmissionStatus.approved);
      await _open(tester, world);
      await _openDetail(tester);
      expect(find.text(zh.workshopMineAboutPending), findsOneWidget);

      await tester.tap(find.byTooltip(zh.workshopMineRefreshOne));
      await settle(tester);
      expect(world.client.details, [personalFirstId]);
      expect(world.client.pages, hasLength(1));
      expect(find.text(zh.workshopMineAboutApproved), findsOneWidget);
      // 详情里的状态和它后面列表里那一行。
      expect(find.widgetWithText(StatusChip, zh.workshopMineStatusApproved), findsNWidgets(2));
    });

    testWidgets('这一条没刷新成：说明显示的是之前的状态，不出现错误码', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
        ..client.readSubmission = (id) async => throw const WorkshopException('workshop_account_unavailable');
      await _open(tester, world);
      await _openDetail(tester);

      await tester.tap(find.byTooltip(zh.workshopMineRefreshOne));
      await settle(tester);
      expect(find.text('${zh.workshopMineDetailStale} ${zh.workshopErrorAccountDown}'), findsOneWidget);
      expect(find.text(zh.workshopMineAboutPending), findsOneWidget);
      expectNoCodes(tester);
    });

    testWidgets('撤回：先要原因，再确认，取消不发；确认后才发一次，成功后状态变成已撤回', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
      await _open(tester, world);
      await _openDetail(tester);

      // 没写原因：字段下面一句话，不弹确认。
      await _askWithdraw(tester, '');
      expect(find.text(zh.workshopMineReasonEmpty), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawConfirmTitle), findsNothing);

      await tester.enterText(find.byType(TextField), '传错了文件');
      await tester.tap(find.text(zh.commonContinue));
      await settle(tester);
      expect(find.text(zh.workshopMineWithdrawConfirmTitle), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawConfirmMessage('小猫')), findsOneWidget);
      expect(world.client.withdrawals, isEmpty);

      await tester.tap(find.text(zh.commonCancel).last);
      await settle(tester);
      expect(world.client.withdrawals, isEmpty);

      await tester.tap(find.text(zh.commonContinue));
      await settle(tester);
      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await tester.pump();
      await tester.pump();
      expect(find.text(zh.workshopMineWithdrawDone), findsOneWidget);
      await settle(tester);
      expect(world.client.withdrawals, [(id: personalFirstId, reason: '传错了文件')]);
      expect(find.text(zh.workshopMineAboutWithdrawn), findsOneWidget);
      expect(find.text(zh.workshopMineWithdraw), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expectNoCodes(tester);
    });

    testWidgets('撤回被明确拒绝：一句人话，可以改了再试', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
        ..client.withdrawSubmission = (id, reason) async => throw const WorkshopException('workshop_rate_limited');
      await _open(tester, world);
      await _openDetail(tester);

      await _askWithdraw(tester, '不想发了');
      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await settle(tester);
      expect(find.text(zh.workshopErrorRateLimited), findsOneWidget);
      expect(find.text(zh.commonContinue), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawDone), findsNothing);
      expectNoCodes(tester);

      // 服务端不收这段原因：错在字段下面。
      world.client.withdrawSubmission = (id, reason) async => throw const WorkshopException('workshop_bad_reason');
      await tester.tap(find.text(zh.commonContinue));
      await settle(tester);
      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await settle(tester);
      expect(find.text(zh.workshopMineReasonRejected), findsOneWidget);
      expect(find.text(zh.workshopErrorRateLimited), findsNothing);
      expectNoCodes(tester);
    });

    testWidgets('撤回结果未知：说不确定，只给查询结果；查到还没撤回才再给撤回', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
        ..client.withdrawSubmission = (id, reason) async => throw _lost;
      await _open(tester, world);
      await _openDetail(tester);

      await _askWithdraw(tester, '不想发了');
      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await settle(tester);

      expect(find.text(zh.workshopMineWithdrawUnknown), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawQuery), findsOneWidget);
      // 没有第二次盲撤的入口，也没有把它说成已撤回。
      expect(find.text(zh.workshopMineWithdraw), findsNothing);
      expect(find.text(zh.commonContinue), findsNothing);
      expect(find.text(zh.workshopMineWithdrawDone), findsNothing);
      expect(find.text(zh.workshopMineAboutPending), findsOneWidget);
      expect(world.client.withdrawals, hasLength(1));
      expectNoCodes(tester);

      // 查询本身失败：还是未知，还是只能查询。
      world.client.readSubmission = (id) async => throw const WorkshopException('workshop_network');
      await tester.tap(find.text(zh.workshopMineWithdrawQuery));
      await settle(tester);
      expect(find.text(zh.workshopMineWithdrawQuery), findsOneWidget);
      expect(find.text(zh.workshopMineWithdraw), findsNothing);

      // 查到它还在：这时再撤回不是盲撤。
      world.client.readSubmission = (id) async => personalRow(id: id);
      await tester.tap(find.text(zh.workshopMineWithdrawQuery));
      await settle(tester);
      expect(world.client.details, [personalFirstId, personalFirstId]);
      expect(find.text(zh.workshopMineWithdrawStill), findsOneWidget);
      expect(find.text(zh.workshopMineWithdraw), findsOneWidget);
      expect(world.client.withdrawals, hasLength(1));
    });

    testWidgets('撤回结果未知，查到已经是撤回状态：照实说现在是撤回状态', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = ((cursor, status) async => WorkshopSubmissionPage([personalRow()], null))
        ..client.withdrawSubmission = ((id, reason) async => throw _lost)
        ..client.readSubmission = (id) async => personalRow(id: id, status: WorkshopSubmissionStatus.withdrawn);
      await _open(tester, world);
      await _openDetail(tester);

      await _askWithdraw(tester, '不想发了');
      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await settle(tester);
      await tester.tap(find.text(zh.workshopMineWithdrawQuery));
      await settle(tester);

      expect(find.text(zh.workshopMineWithdrawReconciled), findsOneWidget);
      expect(find.text(zh.workshopMineAboutWithdrawn), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawUnknown), findsNothing);
      expect(find.text(zh.workshopMineWithdraw), findsNothing);
      expect(world.client.withdrawals, hasLength(1));
    });

    testWidgets('确认时正好有别的操作在跑：撤回没被接纳，只提示稍等，不当成功', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
      final container = await _open(tester, world);
      await _openDetail(tester);
      await _askWithdraw(tester, '不想发了');
      expect(find.text(zh.workshopMineWithdrawConfirmTitle), findsOneWidget);

      final hanging = Completer<WorkshopSubmissionPage>();
      world.client.readPage = (cursor, status) => hanging.future;
      unawaited(container.read(workshopSubmissionsProvider.notifier).refresh());
      await tester.pump();

      await tester.tap(find.text(zh.workshopMineWithdrawConfirm));
      await tester.pump();
      await tester.pump();
      expect(find.text(zh.workshopErrorBusy), findsOneWidget);
      expect(find.text(zh.workshopMineWithdrawDone), findsNothing);
      expect(world.client.withdrawals, isEmpty);

      hanging.complete(WorkshopSubmissionPage([personalRow()], null));
      await settle(tester);
    });

    testWidgets('详情开着时换了账号：不再显示上一个账号的这条投稿', (tester) async {
      usePhoneView(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([personalRow()], null);
      await _open(tester, world);
      await _openDetail(tester);

      world.client.readPage = (cursor, status) async => const WorkshopSubmissionPage([], null);
      world.accountController.emit(
        authSignedIn(
          credential: const WorkshopAccountCredential('TEST_ONLY_KEY_B'),
          userId: 43,
        ),
      );
      await settle(tester);
      expect(find.text(zh.workshopMineAccountChanged), findsOneWidget);
      expect(find.text('小猫'), findsNothing);
      expect(find.text(zh.workshopMineWithdraw), findsNothing);
    });
  });

  group('360dp 宽、字号 1.3', () {
    testWidgets('列表和详情不溢出', (tester) async {
      useNarrowLargeText(tester);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async => WorkshopSubmissionPage([
          personalRow(),
          personalRow(id: personalSecondId, status: WorkshopSubmissionStatus.rejected),
        ], personalSecondId);
      await _open(tester, world);
      expect(find.byType(WorkshopSubmissionRow), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(WorkshopSubmissionRow).last);
      await settle(tester);
      await tester.tap(find.text(zh.workshopMineWithdraw));
      await settle(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('英文界面：用英文标题和状态，也不溢出', (tester) async {
      useNarrowLargeText(tester);
      AppLocale.use(AppLocale.en);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      final en = lookupL10n(AppLocale.en);
      final world = WorkshopPageWorld()
        ..client.readPage = (cursor, status) async =>
            WorkshopSubmissionPage([personalRow(status: WorkshopSubmissionStatus.approved)], null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: world.overrides,
          child: MaterialApp(
            theme: testTheme(Brightness.light),
            locale: AppLocale.en,
            supportedLocales: AppLocale.supported,
            home: _page(),
          ),
        ),
      );
      await settle(tester);

      expect(find.text('Cat'), findsOneWidget);
      expect(find.text(en.workshopMineStatusApproved), findsWidgets);
      expect(find.text(en.workshopMinePublish), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(WorkshopSubmissionRow));
      await settle(tester);
      expect(find.text(en.workshopMineAboutApproved), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
