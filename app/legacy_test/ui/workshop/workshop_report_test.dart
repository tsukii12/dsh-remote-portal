import 'dart:async';

import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/ui/workshop/workshop_report_sheet.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart' show usePhoneView;
import '../../workshop/support.dart' show workshopEntryJson, workshopMeta;
import 'workshop_mine_support.dart';

const _lost = WorkshopException('workshop_timeout', resultUnknown: true);

WorkshopEntry _other() => WorkshopEntry.fromJson(
  workshopEntryJson(
    metadata: workshopMeta(id: 'dog', version: '2.0.0'),
  ),
);

/// A page with one button that opens the report sheet for 小猫 1.0.0.
Future<ProviderContainer> _open(WidgetTester tester, WorkshopPageWorld world) async {
  await tester.pumpWidget(
    world.app(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => unawaited(showWorkshopReportSheet(context, personalEntry())),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
  await tester.tap(find.text('open'));
  await settle(tester);
  expect(find.byType(WorkshopReportSheet), findsOneWidget);
  return ProviderScope.containerOf(tester.element(find.byType(WorkshopReportSheet)));
}

Future<void> _send(WidgetTester tester, String reason) async {
  await tester.enterText(find.byType(TextField), reason);
  await tester.tap(find.text(zh.workshopReportSubmit));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('表单：标题、作品名和版本一行、原因和计数、一个提交按钮', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    await _open(tester, world);

    expect(find.text(zh.workshopReport), findsOneWidget);
    expect(find.text(zh.workshopReportTarget('小猫', '1.0.0')), findsOneWidget);
    expect(find.text(zh.workshopReportReason), findsOneWidget);
    expect(find.text('0/2000'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text(zh.workshopReportSubmit), findsOneWidget);
    // 只说审核员会看，不许诺结果。
    expect(find.text(zh.workshopReportNote), findsOneWidget);
    expectNoCodes(tester);
  });

  testWidgets('原因：没写不发；换行变成空格；按码点计数', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    await _open(tester, world);

    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester, 3);
    expect(find.text(zh.workshopMineReasonEmpty), findsOneWidget);
    expect(world.client.reports, isEmpty);

    await tester.enterText(find.byType(TextField), '抄了别人的图\n没有授权');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '抄了别人的图 没有授权');
    expect(find.text(zh.workshopMineReasonEmpty), findsNothing);

    await tester.enterText(find.byType(TextField), '😀😀');
    await tester.pump();
    expect(find.text('2/2000'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '字' * 2001);
    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester, 3);
    expect(find.text(zh.workshopMineReasonTooLong('2000')), findsOneWidget);
    expect(world.client.reports, isEmpty);
  });

  testWidgets('没登录：说明要账号，给出登录，不给表单', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld(account: authSignedOut);
    await _open(tester, world);

    expect(find.text(zh.workshopReportSignInTitle), findsOneWidget);
    expect(find.text(zh.workshopSignInTitle), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text(zh.workshopReportSubmit), findsNothing);
    expectNoCodes(tester);

    await tester.tap(find.text(zh.workshopSignInTitle));
    await settle(tester);
    expect(find.text('TEST-CODE'), findsOneWidget);
  });

  testWidgets('还没同意交出凭据：先看说明，同意后才有表单', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld(consent: false);
    await _open(tester, world);

    expect(find.text(zh.workshopReportConsentMessage), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text(zh.workshopMineConsentAction));
    await settle(tester);
    expect(find.text('workshop.example'), findsOneWidget);
    expect(find.text('github.com'), findsOneWidget);
    await tester.tap(find.text(zh.workshopDisclosureAccept));
    await settle(tester);

    expect(world.preferences.writes, 1);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(zh.workshopReportSubmit), findsOneWidget);
  });

  testWidgets('送达：只发一次，弹层收起，一句提示', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld();
    await _open(tester, world);

    await _send(tester, '抄了别人的图');
    expect(find.text(zh.workshopReportDone), findsOneWidget);
    await settle(tester);
    expect(world.client.reports, [(kind: 'pet', id: 'cat', version: '1.0.0', reason: '抄了别人的图')]);
    expect(find.byType(WorkshopReportSheet), findsNothing);
    expectNoCodes(tester);
  });

  testWidgets('发送途中：按钮停用，不会发第二次', (tester) async {
    usePhoneView(tester);
    final answer = Completer<String>();
    final world = WorkshopPageWorld()..client.sendReport = (kind, id, version, reason) => answer.future;
    await _open(tester, world);

    await _send(tester, '抄了别人的图');
    expect(find.text(zh.workshopReportSending), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(world.client.reports, hasLength(1));

    answer.complete(personalThirdId);
    await settle(tester);
    expect(find.byType(WorkshopReportSheet), findsNothing);
    expect(world.client.reports, hasLength(1));
  });

  testWidgets('被明确拒绝：一句人话，没有错误码，可以再提交', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()
      ..client.sendReport = (kind, id, version, reason) async => throw const WorkshopException('workshop_rate_limited');
    await _open(tester, world);

    await _send(tester, '抄了别人的图');
    await settle(tester, 3);
    expect(find.text(zh.workshopErrorRateLimited), findsOneWidget);
    expect(find.byType(WorkshopReportSheet), findsOneWidget);
    expect(find.text(zh.workshopReportDone), findsNothing);
    expectNoCodes(tester);

    // 服务端不收这段原因：错在字段下面。
    world.client.sendReport = (kind, id, version, reason) async => throw const WorkshopException('workshop_bad_reason');
    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester, 3);
    expect(find.text(zh.workshopMineReasonRejected), findsOneWidget);
    expect(find.text(zh.workshopErrorRateLimited), findsNothing);
    expect(world.client.reports, hasLength(2));
    expectNoCodes(tester);

    world.client.sendReport = null;
    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester);
    expect(world.client.reports, hasLength(3));
    expect(find.byType(WorkshopReportSheet), findsNothing);
  });

  testWidgets('结果未知：说可能已收到、再发可能重复；点了那个按钮才回到表单，回到表单也不自动发', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()..client.sendReport = (kind, id, version, reason) async => throw _lost;
    final container = await _open(tester, world);

    await _send(tester, '抄了别人的图');
    await settle(tester, 3);
    expect(find.text(zh.workshopReportUnknownTitle), findsOneWidget);
    expect(find.text(zh.workshopReportUnknownMessage), findsOneWidget);
    // 没有表单，没有「提交举报」，没有重试，也没说成功。
    expect(find.byType(TextField), findsNothing);
    expect(find.text(zh.workshopReportSubmit), findsNothing);
    expect(find.text(zh.commonRetry), findsNothing);
    expect(find.text(zh.workshopReportDone), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(world.client.reports, hasLength(1));
    expectNoCodes(tester);

    final shown = container.read(workshopReportProvider).attempt;
    await tester.tap(find.text(zh.workshopReportUnknownAgain));
    await settle(tester, 3);
    // 只是开始新的一次：原来写的还在，什么都没发。
    expect(container.read(workshopReportProvider).phase, WorkshopReportPhase.idle);
    expect(shown, isNotNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '抄了别人的图');
    expect(world.client.reports, hasLength(1));

    world.client.sendReport = null;
    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester);
    expect(world.client.reports, hasLength(2));
    expect(find.byType(WorkshopReportSheet), findsNothing);
  });

  testWidgets('结果未知后关掉再打开：还是先说明，不能直接再发', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()..client.sendReport = (kind, id, version, reason) async => throw _lost;
    await _open(tester, world);
    await _send(tester, '抄了别人的图');
    await settle(tester, 3);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);

    expect(find.text(zh.workshopReportUnknownTitle), findsOneWidget);
    expect(find.text(zh.workshopReportSubmit), findsNothing);
    expect(world.client.reports, hasLength(1));

    // 说明后回到表单，带回上次写的原因。
    await tester.tap(find.text(zh.workshopReportUnknownAgain));
    await settle(tester, 3);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '抄了别人的图');
    expect(world.client.reports, hasLength(1));
  });

  testWidgets('上一次未知的举报是别的作品：说清是哪一个', (tester) async {
    usePhoneView(tester);
    final world = WorkshopPageWorld()..client.sendReport = (kind, id, version, reason) async => throw _lost;
    await tester.pumpWidget(world.app(const Scaffold(body: SizedBox())));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    await container.read(workshopReportProvider.notifier).submit(_other(), '别的问题');
    expect(container.read(workshopReportProvider).phase, WorkshopReportPhase.unknown);

    unawaited(showWorkshopReportSheet(tester.element(find.byType(Scaffold)), personalEntry()));
    await settle(tester);
    expect(
      find.text('${zh.workshopReportUnknownMessage} ${zh.workshopReportUnknownOther('dog', '2.0.0')}'),
      findsOneWidget,
    );

    await tester.tap(find.text(zh.workshopReportUnknownAgain));
    await settle(tester, 3);
    // 这一张表单是给小猫的，不带别的作品的原因。
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(world.client.reports, hasLength(1));
  });

  testWidgets('另一条举报还在发时这里发不出去；它结束后这一条照常发，不用重开弹层', (tester) async {
    usePhoneView(tester);
    final gate = Completer<String>();
    final world = WorkshopPageWorld();
    world.client.sendReport = (kind, id, version, reason) =>
        id == _other().metadata.id ? gate.future : Future.value('r-2');
    final container = await _open(tester, world);
    await tester.enterText(find.byType(TextField), '抄了别人的图');

    // 表单开着时，另一条举报还没有结果：按钮停用，什么也不发。
    unawaited(container.read(workshopReportProvider.notifier).submit(_other(), '别的问题'));
    await settle(tester);
    expect(world.client.reports, hasLength(1));
    expect(find.text(zh.workshopReportSubmit), findsNothing);
    await tester.tap(find.text(zh.workshopReportSending), warnIfMissed: false);
    await tester.pump();
    expect(world.client.reports, hasLength(1));

    // 那一条结束了（成功）：它不是这一项的举报，弹层不收，也不挡这一条。
    gate.complete('r-1');
    await settle(tester);
    expect(find.byType(WorkshopReportSheet), findsOneWidget);
    expect(find.text(zh.workshopReportDone), findsNothing);

    await tester.tap(find.text(zh.workshopReportSubmit));
    await settle(tester);
    expect(find.text(zh.workshopErrorBusy), findsNothing);
    expect(world.client.reports, hasLength(2));
    expect(world.client.reports.last.reason, '抄了别人的图');
    expect(find.byType(WorkshopReportSheet), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('360dp 宽、字号 1.3：表单和未知说明都不溢出', (tester) async {
    useNarrowLargeText(tester);
    final world = WorkshopPageWorld()..client.sendReport = (kind, id, version, reason) async => throw _lost;
    await _open(tester, world);
    expect(tester.takeException(), isNull);

    await _send(tester, '抄了别人的图');
    await settle(tester, 3);
    expect(find.text(zh.workshopReportUnknownTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
