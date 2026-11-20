// LinkRouter's file fallback: files opened with the app that no feature
// registered an extension for go to the new-chat composer instead of the
// 「无法打开这个文件」 toast; registered extensions (.dshgo) still win.

import 'dart:async';

import 'package:dsh_app/links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('extension handlers first, then the fallback, else the toast', (tester) async {
    final links = StreamController<Uri>();
    final router = LinkRouter(links.stream, grace: Duration.zero);
    addTearDown(() {
      router.dispose();
      unawaited(links.close());
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final toasts = <String>[];
    router.attach(tester.element(find.byType(SizedBox)), toast: toasts.add);

    final codes = <Uri>[];
    final others = <Uri>[];
    router.registerFileHandler('dshgo', (uri) async {
      codes.add(uri);
      return true;
    });
    final off = router.registerFileFallback((uri) async {
      others.add(uri);
      return true;
    });
    await tester.pump();

    links
      ..add(Uri.file('/c/links/1/读书笔记.dshgo'))
      ..add(Uri.file('/c/links/2/notes.md'))
      ..add(Uri.file('/c/links/3/README'));
    await tester.pump();
    expect(codes.map((u) => u.pathSegments.last), ['读书笔记.dshgo']);
    expect(others.map((u) => u.pathSegments.last), ['notes.md', 'README']);
    expect(toasts, isEmpty);

    // Links are not files: the fallback never sees them.
    links.add(Uri.parse('dshgo://nowhere'));
    await tester.pump();
    expect(others, hasLength(2));
    expect(toasts, ['无法打开这个链接']);

    off();
    links.add(Uri.file('/c/links/4/a.bin'));
    await tester.pump();
    expect(others, hasLength(2));
    expect(toasts.last, '无法打开这个文件');
  });

  testWidgets('a fallback that declines gets the toast', (tester) async {
    final links = StreamController<Uri>();
    final router = LinkRouter(links.stream, grace: Duration.zero);
    addTearDown(() {
      router.dispose();
      unawaited(links.close());
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final toasts = <String>[];
    router.attach(tester.element(find.byType(SizedBox)), toast: toasts.add);
    router.registerFileFallback((uri) async => false);
    links.add(Uri.file('/c/links/1/a.bin'));
    await tester.pump();
    expect(toasts, ['无法打开这个文件']);
  });
}
