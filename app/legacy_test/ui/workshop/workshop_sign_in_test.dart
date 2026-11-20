import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/ui/workshop/workshop_sign_in.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/account.dart' show FakeBrowser;
import '../../chat/support/harness.dart' show testApp;

/// The sheet's side of the account: what it asked for, and a state the test sets.
class _Account extends WorkshopAccountController {
  int starts = 0, cancels = 0;

  @override
  WorkshopAccountState build() => const WorkshopAccountState(phase: WorkshopAccountPhase.signedOut);

  @override
  Future<void> startSignIn() async => starts++;

  @override
  void cancelSignIn() => cancels++;

  void show(WorkshopAccountState next) => state = next;
}

/// The sheet keeps a ring turning while it waits, so it never settles on its own.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  late _Account account;
  late FakeBrowser browser;
  late List<String> copied;

  Future<void> open(WidgetTester tester) async {
    account = _Account();
    browser = FakeBrowser();
    copied = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(testApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => showWorkshopSignInSheet(context), child: const Text('go')),
        ),
      ),
      overrides: [
        workshopAccountProvider.overrideWith(() => account),
        accountBrowserProvider.overrideWithValue(browser),
      ],
    ));
    await tester.tap(find.text('go'));
    await settle(tester);
  }

  testWidgets('asks for a code as it opens, then copies it and opens GitHub in one tap', (tester) async {
    await open(tester);
    expect(account.starts, 1);
    expect(find.text('正在向 GitHub 要验证码…'), findsOneWidget);

    account.show(WorkshopAccountState(
      phase: WorkshopAccountPhase.awaitingCode,
      userCode: 'WDJB-MJHT',
      verificationUri: Uri.parse('https://github.com/login/device'),
    ));
    await settle(tester);
    expect(find.text('WDJB-MJHT'), findsOneWidget);
    expect(find.text('等你在 GitHub 上授权…'), findsOneWidget);

    await tester.tap(find.text('复制并打开 GitHub'));
    await settle(tester);
    expect(copied, ['WDJB-MJHT']);
    expect(browser.opened, [Uri.parse('https://github.com/login/device')]);
    expect(find.text('验证码已复制'), findsOneWidget);
  });

  testWidgets('closes itself once signed in, and stops waiting when closed', (tester) async {
    await open(tester);
    account.show(const WorkshopAccountState(phase: WorkshopAccountPhase.signedIn, id: 7, login: 'octo'));
    await settle(tester);
    expect(find.text('用 GitHub 登录'), findsNothing);
    expect(account.cancels, 1);
  });

  testWidgets('a failed attempt says why; only a deployment without GitHub sign-in offers no retry', (tester) async {
    await open(tester);
    account.show(const WorkshopAccountState(phase: WorkshopAccountPhase.signedOut, error: WorkshopAccountError.expired));
    await settle(tester);
    expect(find.text('验证码过期了。'), findsOneWidget);
    await tester.tap(find.text('重新获取验证码'));
    expect(account.starts, 2);

    account.show(const WorkshopAccountState(phase: WorkshopAccountPhase.signedOut, error: WorkshopAccountError.unconfigured));
    await settle(tester);
    expect(find.text('这个工坊还没开通 GitHub 登录。'), findsOneWidget);
    expect(find.text('重新获取验证码'), findsNothing);
  });
}
