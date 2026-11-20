// The address shown before a credential is handed over
// (ui/workshop/workshop_text.dart): what is on screen must name one host.

import 'package:dsh_app/ui/workshop/workshop_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a host, with its port when it has one', () {
    expect(workshopHostText(Uri.parse('https://workshop.example')), 'workshop.example');
    expect(workshopHostText(Uri.parse('https://workshop.example:8443')), 'workshop.example:8443');
  });

  test('an IPv6 host keeps its brackets, so the port is not read as part of it', () {
    expect(workshopHostText(Uri.parse('https://[2001:db8::1]:8443')), '[2001:db8::1]:8443');
    expect(workshopHostText(Uri.parse('https://[2001:db8::1:8443]')), '[2001:db8::1:8443]');
  });
}
