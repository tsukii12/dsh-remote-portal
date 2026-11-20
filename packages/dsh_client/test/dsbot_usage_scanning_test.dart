import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('real scan responses distinguish partial from complete zero totals', () {
    final fixture = jsonDecode(File('test/fixtures/dsbot_usage_scanning.json').readAsStringSync()) as Map;
    final during = DsBotUsageSummary.fromJson(fixture['during']['value']);
    final after = DsBotUsageSummary.fromJson(fixture['after']['value']);
    expect(during.scanning, isTrue);
    expect(after.scanning, isFalse);
    expect(during.day.total, 0);
    expect(after.day.total, 0);
    expect(DsBotUsageSummary.fromJson({}).scanning, isFalse);
  });
}
