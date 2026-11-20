import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('an absolute trailing space keeps two existing files distinct', () async {
    final directory = await Directory.systemTemp.createTemp('session-path-whitespace-');
    addTearDown(() => directory.delete(recursive: true));
    final ordinary = File('${directory.path}/report.pdf');
    final spaced = File('${directory.path}/report.pdf ');
    await ordinary.writeAsString('ordinary sibling');
    await spaced.writeAsString('requested trailing-space file');

    final resolved = resolveSessionPath(spaced.path);
    expect(await File(resolved).readAsString(), 'requested trailing-space file');
    expect(resolved, spaced.path);
    expect(await ordinary.readAsString(), 'ordinary sibling');
  });

  test('relative path boundary whitespace belongs to the filename', () {
    for (final name in [' report.pdf', 'report.pdf ', ' report.pdf ', 'report.pdf\u00a0']) {
      expect(resolveSessionPath(name, cwd: '/root/workspace'), '/root/workspace/$name');
      expect(resolveSessionPath(name), name);
    }
  });

  test('dot and slash folding preserves the remaining segment whitespace', () {
    expect(resolveSessionPath('/root//out/./report.pdf '), '/root/out/report.pdf ');
    expect(resolveSessionPath(' folder/../ report.pdf ', cwd: '/root'), '/root/ report.pdf ');
  });

  test('file URI decoding and ordinary path controls retain their behavior', () {
    expect(resolveSessionPath('file:///tmp/%20report.pdf%20'), '/tmp/ report.pdf ');
    expect(resolveSessionPath('file:///tmp/100%25.png'), '/tmp/100%.png');
    expect(resolveSessionPath('./a/../report.pdf', cwd: '/root'), '/root/report.pdf');
    expect(resolveSessionPath(r'C:\work\report.pdf', cwd: '/root'), r'C:\work\report.pdf');
    expect(resolveSessionPath('report.pdf'), 'report.pdf');
  });
}
