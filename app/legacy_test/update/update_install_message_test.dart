import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('Chinese unknown outcome does not claim cancellation or native submission', () {
    AppLocale.use(AppLocale.zhCN);
    expect(describeUpdateProblem(UpdateProblem.installUnconfirmed), (
      '尚未确认安装结果',
      '安装包已保留。可先检查系统提示，再重试或用系统安装器打开。',
    ));
    expect(describeUpdateProblem(UpdateProblem.installCancelled).$1, '已取消安装');
  });

  test('English unknown outcome remains distinct from explicit cancellation', () {
    AppLocale.use(AppLocale.en);
    expect(describeUpdateProblem(UpdateProblem.installUnconfirmed), (
      'Installation result not confirmed',
      'The package is saved. Check any system prompts, then retry or open it with the system installer.',
    ));
    expect(describeUpdateProblem(UpdateProblem.installCancelled).$1, isNot('Installation result not confirmed'));
  });
}
