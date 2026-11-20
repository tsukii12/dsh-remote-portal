import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../files/support/memory_workspace.dart';

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  test('workspace destinations keep URL schemes out of file previews', () {
    for (final target in [
      '',
      ' ',
      '#section',
      '?download=1',
      '//example.com/file.js',
      'file://example.com/file.js',
      'file://user@localhost/file.js',
      'file://localhost:80/file.js',
      'https://example.com/file.js',
      'http://example.com',
      'mailto:user@example.com',
      'javascript:alert(1)',
      'intent://open',
      'dshgo://open',
      'data:text/plain,hello',
      'tel:123',
      'file%3A%2F%2F%252Froot',
      'bad%FFname.js',
    ]) {
      expect(MarkdownBody.workspaceLinkPath(target), isNull, reason: target);
    }
    expect(MarkdownBody.workspaceLinkPath('lesson01-demo.js'), 'lesson01-demo.js');
    expect(MarkdownBody.workspaceLinkPath('file:///root/work/demo.js#L4'), '/root/work/demo.js');
    expect(MarkdownBody.workspaceLinkPath('file://localhost/root/work/demo.js'), '/root/work/demo.js');
    expect(MarkdownBody.workspaceLinkPath('笔记/例子.js'), '笔记/例子.js');
    expect(MarkdownBody.workspaceLinkPath('out/a%20b.js'), 'out/a b.js');
    expect(MarkdownBody.workspaceLinkPath('out/a%23b.js'), 'out/a#b.js');
    expect(MarkdownBody.workspaceLinkPath('out/a%252Fb.js'), 'out/a%2Fb.js');
    expect(MarkdownBody.workspaceLinkPath('%252e%252e/a.js', baseDir: '/root/work'), '/root/work/%2e%2e/a.js');
    expect(MarkdownBody.workspaceLinkPath('file:///root/a%252Fb.js'), '/root/a%2Fb.js');
    expect(MarkdownBody.workspaceLinkPath('<out/a b.js>'), 'out/a b.js');
    expect(MarkdownBody.workspaceLinkPath('../code/a.js#L9', baseDir: '/root/docs'), '/root/code/a.js');
    expect(MarkdownBody.workspaceLinkPath('a.js?download=1#L9', baseDir: '/root/docs'), '/root/docs/a.js');
    expect(MarkdownBody.workspaceLinkPath('code/a.js', baseDir: 'docs'), 'docs/code/a.js');
    expect(MarkdownBody.workspaceLinkPath('../a.js', baseDir: 'docs/chapter'), 'docs/chapter/../a.js');
    expect(MarkdownBody.workspaceLinkPath('/root/a.js', baseDir: 'docs'), '/root/a.js');
  });

  test('external URL allowlist remains unchanged', () {
    for (final target in ['https://example.com/a', 'http://example.com/a', 'mailto:a@example.com']) {
      expect(MarkdownBody.linkToOpen(target), Uri.parse(target));
    }
    for (final target in ['lesson.js', 'file:///root/a.js', 'intent://open', 'javascript:alert(1)', 'tel:123']) {
      expect(MarkdownBody.linkToOpen(target), isNull);
    }
  });

  testWidgets('cached callback reads the latest scope and routes to existing preview', (tester) async {
    final observer = _Routes();
    final theme = buildLightTheme();
    Widget app(String session, String baseDir) => MaterialApp(
      theme: theme,
      navigatorObservers: [observer],
      home: Scaffold(
        body: MarkdownImageScope(
          sessionId: session,
          baseDir: baseDir,
          child: MarkdownBody(text: '[file](lesson01-demo.js)', selectable: false),
        ),
      ),
    );
    await tester.pumpWidget(app('old-session', '/root/old'));
    final oldMarkdown = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
    final cachedTap = oldMarkdown.onLinkTap!;
    final oldRich = tester
        .widgetList<RichText>(find.byWidgetPredicate((w) => w is RichText))
        .where((w) => w.text.toPlainText() == 'file')
        .toList();
    expect(oldRich, isNotEmpty);
    await tester.pumpWidget(app('new-session', '/root/new'));
    final newRich = tester
        .widgetList<RichText>(find.byWidgetPredicate((w) => w is RichText))
        .where((w) => w.text.toPlainText() == 'file')
        .toList();
    expect(
      identical(oldRich.single, newRich.single),
      isTrue,
      reason: 'The unchanged settled Markdown segment keeps its widget cache.',
    );
    final count = observer.pushed.length;
    cachedTap('lesson01-demo.js', 'file');
    expect(observer.pushed.length, count + 1);
    final route = observer.pushed.last as MaterialPageRoute<void>;
    final page = route.builder(tester.element(find.byType(MarkdownBody))) as ArtifactPreviewPage;
    expect(page.sessionId, 'new-session');
    expect(page.artifact.path, '/root/new/lesson01-demo.js');
    // Unmount before the preview builds: this checks dispatch without engine,
    // file bytes, platform channels, bundled fonts, or screenshot assertions.
    await tester.pumpWidget(const SizedBox.shrink());
    cachedTap('lesson01-demo.js', 'file');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unscoped Markdown does not borrow another conversation', (tester) async {
    final observer = _Routes();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        navigatorObservers: [observer],
        home: const Scaffold(body: MarkdownBody(text: '[file](a.js)', selectable: false)),
      ),
    );
    final count = observer.pushed.length;
    tester.widget<GptMarkdown>(find.byType(GptMarkdown)).onLinkTap!('a.js', 'file');
    expect(observer.pushed.length, count);
    expect(tester.takeException(), isNull);
  });

  test('a bare domain reads as a website; a file name stays a file', () {
    for (final (target, site) in [
      ('example.com', 'https://example.com'),
      ('www.example.com/docs?a=1#top', 'https://www.example.com/docs?a=1#top'),
      ('docs.python.org/3/library/os.html', 'https://docs.python.org/3/library/os.html'),
      ('github.io', 'https://github.io'),
      ('deepseek.cn', 'https://deepseek.cn'),
      ('<example.org>', 'https://example.org'),
    ]) {
      expect(MarkdownBody.bareDomainLink(target), Uri.parse(site), reason: target);
    }
    for (final target in [
      'notes.md',
      'main.py',
      'lib.rs',
      'build.sh',
      'app.js',
      'index.ts',
      'archive.zip',
      'clip.mov',
      'next.config',
      'README',
      'src/app.js',
      './example.com',
      '/root/example.com',
      '../example.com',
      'lesson01-demo.js',
      'v1.0',
      '1.2.3',
      'https://example.com',
      'file:///root/a.com',
      'mailto:a@example.com',
      '//example.com',
      'exa mple.com',
      '笔记.com',
      '',
    ]) {
      expect(MarkdownBody.bareDomainLink(target), isNull, reason: target);
    }
  });

  Widget scoped(_Routes observer, MemoryWorkspace workspace, String text) => ProviderScope(
    overrides: [workspaceSourceProvider.overrideWith((ref, id) => workspace)],
    child: MaterialApp(
      theme: buildLightTheme(),
      navigatorObservers: [observer],
      home: Scaffold(
        body: MarkdownImageScope(
          sessionId: 's1',
          baseDir: '/root/work',
          child: MarkdownBody(text: text, selectable: false),
        ),
      ),
    ),
  );

  void tap(WidgetTester tester, String url) => tester.widget<GptMarkdown>(find.byType(GptMarkdown)).onLinkTap!(url, '');

  testWidgets('a bare domain with no such file asks to open the site', (tester) async {
    final observer = _Routes();
    final workspace = MemoryWorkspace();
    await tester.pumpWidget(scoped(observer, workspace, '[官网](example.com)'));
    final count = observer.pushed.length;
    tap(tester, 'example.com');
    await tester.pumpAndSettle();
    expect(workspace.calls, ['stat example.com']);
    expect(find.text('在浏览器打开 example.com？'), findsOneWidget);
    // The browser prompt only: no 「文件不存在」 preview behind it.
    expect(observer.pushed.skip(count).whereType<PageRoute<dynamic>>(), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('在浏览器打开 example.com？'), findsNothing);
  });

  testWidgets('a bare domain that is a workspace file opens the file', (tester) async {
    final observer = _Routes();
    final workspace = MemoryWorkspace(files: {'example.com': 'not a website'});
    await tester.pumpWidget(scoped(observer, workspace, '[file](example.com)'));
    final count = observer.pushed.length;
    tap(tester, 'example.com');
    await tester.pump();
    await tester.pump();
    expect(find.text('在浏览器打开 example.com？'), findsNothing);
    expect(observer.pushed.length, count + 1);
    final route = observer.pushed.last as MaterialPageRoute<void>;
    final page = route.builder(tester.element(find.byType(MarkdownBody))) as ArtifactPreviewPage;
    expect(page.artifact.path, '/root/work/example.com');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a file name keeps the preview without asking the Host first', (tester) async {
    final observer = _Routes();
    final workspace = MemoryWorkspace();
    await tester.pumpWidget(scoped(observer, workspace, '[notes](notes.md)'));
    final count = observer.pushed.length;
    tap(tester, 'notes.md');
    expect(observer.pushed.length, count + 1);
    expect(workspace.calls, isEmpty);
    final route = observer.pushed.last as MaterialPageRoute<void>;
    final page = route.builder(tester.element(find.byType(MarkdownBody))) as ArtifactPreviewPage;
    expect(page.artifact.path, '/root/work/notes.md');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a bare domain outside any conversation still asks to open the site', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: MarkdownBody(text: '[官网](example.com)', selectable: false)),
      ),
    );
    tap(tester, 'example.com');
    await tester.pumpAndSettle();
    expect(find.text('在浏览器打开 example.com？'), findsOneWidget);
  });
}
