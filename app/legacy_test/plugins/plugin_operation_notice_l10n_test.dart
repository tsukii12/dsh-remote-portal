import 'package:dsh_app/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retired plugin operation notice uses the requested Chinese copy', () {
    expect(lookupL10n(const Locale('zh', 'CN')).pluginsOperationHostChanged, '主机已切换，未执行');
  });

  test('retired plugin operation notice uses the requested English copy', () {
    expect(lookupL10n(const Locale('en')).pluginsOperationHostChanged, 'Host changed — nothing was done');
  });
}
