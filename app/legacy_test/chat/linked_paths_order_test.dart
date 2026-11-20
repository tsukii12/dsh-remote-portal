import 'package:dsh_app/state/artifacts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('many links keep first resolved occurrence order across duplicates and filtered targets', () {
    final markdown = StringBuffer();
    final expected = <String>[];
    for (var i = 511; i >= 0; i--) {
      markdown.write('[first](reports/a%20$i.pdf) [alias](<reports/a%20$i.pdf>) ');
      markdown.write('[web](https://example.invalid/$i.pdf) [anchor](#a$i) [duplicate](reports/a%20$i.pdf) ');
      expected.add('/work/reports/a $i.pdf');
    }
    final paths = linkedPaths(markdown.toString(), cwd: '/work');
    expect(paths, expected);
    paths.add('/work/extra.pdf');
    expect(paths.removeLast(), '/work/extra.pdf');
    paths[0] = '/work/replaced.pdf';
    expect(paths.length, 512);
  });

  test('empty result remains growable', () {
    final paths = linkedPaths('[web](https://example.invalid/a.pdf) [anchor](#a)');
    expect(paths, isEmpty);
    paths.add('/a.pdf');
    expect(paths, ['/a.pdf']);
    paths.clear();
    expect(paths, isEmpty);
  });

  test('distinct Unicode and Windows paths retain order without normalizing case or whitespace', () {
    const markdown =
        '[a](report.pdf%20) [b](report.pdf) [c](报告.pdf) '
        '[d](REPORT.pdf) [e](C:/work/报告.pdf#L2) [f](C:/work/报告.pdf) [again](报告.pdf)';
    expect(linkedPaths(markdown, cwd: '/work'), [
      '/work/report.pdf ',
      '/work/report.pdf',
      '/work/报告.pdf',
      '/work/REPORT.pdf',
      'C:/work/报告.pdf',
    ]);
  });
}
