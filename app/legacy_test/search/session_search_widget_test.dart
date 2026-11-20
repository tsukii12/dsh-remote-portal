// The search page and the drawer's search bar.
//
//   flutter test test/search

import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

List<Override> searchOverrides(FakeContentSearch backend, {String? current}) => [
  sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
  sessionContentSearchProvider.overrideWithValue(backend),
  currentSessionProvider.overrideWith(() => FakeCurrentSession(current)),
];

Future<void> pumpPage(
  WidgetTester tester,
  FakeContentSearch backend, {
  String? current,
  bool archivedOnly = false,
}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: SessionSearchPage(now: searchNow, archivedOnly: archivedOnly),
      brightness: Brightness.light,
      overrides: searchOverrides(backend, current: current),
    ),
  );
  await tester.pump();
}

/// Lets the debounce run out and the fake Host answer.
Future<void> settleSearch(WidgetTester tester) async {
  await tester.pump(SessionSearchController.debounce);
  await tester.pump();
  await tester.pump();
}

Finder tileOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(SearchResultTile));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('archive browser lists archived chats before searching and never mixes active hits', (tester) async {
    final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
    await pumpPage(tester, backend, archivedOnly: true);
    expect(find.byType(SearchResultTile), findsOneWidget);
    expect(tileOf('旧版登录接口迁移笔记'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isFalse);
    expect(backend.calls, isEmpty);

    await tester.enterText(find.byType(TextField), '登录');
    await settleSearch(tester);
    expect(find.byType(SearchResultTile), findsOneWidget);
    expect(tileOf('修复登录按钮重复提交'), findsNothing);
    expect(tileOf('Retrofit 拦截器加 token 刷新'), findsNothing);

    await tester.enterText(find.byType(TextField), 'README');
    await settleSearch(tester);
    expect(find.byType(SearchResultTile), findsNothing);
    expect(find.text('没有相关对话'), findsOneWidget);
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    expect(tileOf('旧版登录接口迁移笔记'), findsOneWidget);
  });

  testWidgets('titles match as you type; the Host adds content hits after a pause', (tester) async {
    final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
    await pumpPage(tester, backend);
    expect(find.text('搜索「本机」上的对话'), findsOneWidget);
    expect(find.text('按标题和内容查找，含已归档的对话'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '登录');
    await tester.pump();
    expect(find.byType(SearchResultTile), findsNWidgets(3));
    expect(tileOf('修复登录按钮重复提交'), findsOneWidget);
    expect(tileOf('登录页加上记住密码'), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget); // the archived section
    expect(find.text('正在搜索消息内容…'), findsOneWidget);
    expect(backend.calls, isEmpty);

    await settleSearch(tester);
    expect(backend.calls, ['登录']);
    expect(find.text('正在搜索消息内容…'), findsNothing);
    expect(find.byType(SearchResultTile), findsNWidgets(4));
    expect(tileOf('Retrofit 拦截器加 token 刷新'), findsOneWidget);
    // The excerpt is re-windowed to show the match, and the match is highlighted.
    final excerpt = tester
        .widgetList<HighlightedText>(find.byType(HighlightedText))
        .firstWhere((t) => t.text.contains('跳回「登录」页'));
    expect(excerpt.text, startsWith('…'));
    expect(excerpt.ranges, hasLength(1));
    expect(excerpt.text.substring(excerpt.ranges.single.start, excerpt.ranges.single.end), '登录');
    final title = tester
        .widgetList<HighlightedText>(find.byType(HighlightedText))
        .firstWhere((t) => t.text == '修复登录按钮重复提交');
    expect(title.ranges, [(start: 2, end: 4)]);
    expect(find.text('14:05'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
  });

  testWidgets('picking a result pops with its id', (tester) async {
    final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
    String? picked;
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: searchOverrides(backend),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => picked = await showSessionSearch(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '登录');
    await settleSearch(tester);
    await tester.tap(tileOf('Retrofit 拦截器加 token 刷新'));
    await tester.pumpAndSettle();
    expect(picked, 's4');
    expect(find.byType(SessionSearchPage), findsNothing);
  });

  testWidgets('the drawer bar opens search; a pick selects the session and closes the drawer', (tester) async {
    final backend = FakeContentSearch();
    var closed = false;
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: searchOverrides(backend, current: 's1'),
        home: Scaffold(
          body: SafeArea(child: SessionSearchBar(onClose: () => closed = true)),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('搜索对话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionSearchPage), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'readme');
    await settleSearch(tester);
    await tester.tap(tileOf('把 README 翻译成英文'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(SessionSearchBar)));
    expect(container.read(currentSessionProvider), 's6');
    expect(closed, isTrue);
  });

  testWidgets('back leaves search without picking', (tester) async {
    var closed = false;
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: searchOverrides(FakeContentSearch()),
        home: Scaffold(
          body: SafeArea(child: SessionSearchBar(onClose: () => closed = true)),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('搜索对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(closed, isFalse);
  });

  testWidgets('an IME composition does not search; the committed text does', (tester) async {
    final backend = FakeContentSearch();
    await pumpPage(tester, backend);
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'denglu',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.calls, isEmpty);
    expect(find.text('没有相关对话'), findsNothing);
    expect(find.text('搜索「本机」上的对话'), findsOneWidget);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '登录', selection: TextSelection.collapsed(offset: 2)),
    );
    await settleSearch(tester);
    expect(backend.calls, ['登录']);
    expect(find.byType(SearchResultTile), findsNWidgets(3));
  });

  testWidgets('nothing found on a host without content search says so', (tester) async {
    final backend = FakeContentSearch(error: searchDisabled);
    await pumpPage(tester, backend);
    await tester.enterText(find.byType(TextField), 'webview 白屏');
    await settleSearch(tester);
    expect(find.text('没有相关对话'), findsOneWidget);
    expect(find.text('这台主机仅支持按标题搜索'), findsOneWidget);
    // The next query doesn't ask again.
    await tester.enterText(find.byType(TextField), '深色');
    await settleSearch(tester);
    expect(backend.calls, ['webview 白屏']);
    expect(tileOf('给设置页加深色模式'), findsOneWidget);
    expect(find.text('这台主机仅支持按标题搜索'), findsOneWidget);
  });

  testWidgets('a failed content search can be retried', (tester) async {
    final backend = FakeContentSearch(
      results: {'登录': (items: loginHits, hasMore: true)},
      error: const DshTransportException('socket closed'),
    );
    await pumpPage(tester, backend);
    await tester.enterText(find.byType(TextField), '登录');
    await settleSearch(tester);
    expect(find.text('内容搜索失败，仅显示标题匹配'), findsOneWidget);
    expect(find.byType(SearchResultTile), findsNWidgets(3));
    backend.error = null;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SearchResultTile), findsNWidgets(4));
    expect(find.text('内容匹配仅列出最相关的 20 个对话'), findsOneWidget);
  });

  testWidgets('an archived result asks before restoring', (tester) async {
    await pumpPage(tester, FakeContentSearch());
    await tester.enterText(find.byType(TextField), '迁移');
    await settleSearch(tester);
    await tester.tap(tileOf('旧版登录接口迁移笔记'));
    await tester.pumpAndSettle();
    expect(find.text('已归档的对话需先恢复，才能打开'), findsOneWidget);
    // Not connected in this test: the restore fails and says so.
    await tester.tap(find.text('恢复并打开'));
    await tester.pumpAndSettle();
    expect(find.text('没能恢复，稍后再试'), findsOneWidget);
    expect(find.byType(SessionSearchPage), findsOneWidget);
  });

  testWidgets('clearing the field returns to the hint', (tester) async {
    await pumpPage(tester, FakeContentSearch());
    await tester.enterText(find.byType(TextField), '深色');
    await settleSearch(tester);
    expect(find.byType(SearchResultTile), findsOneWidget);
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    expect(find.byType(SearchResultTile), findsNothing);
    expect(find.text('搜索「本机」上的对话'), findsOneWidget);
  });

  testWidgets('small screen, large text: nothing overflows', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    addTearDown(tester.view.reset);
    final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: true)});
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: searchOverrides(backend, current: 's2'),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: Column(
                children: [
                  SizedBox(width: 264, child: SessionSearchBar(onClose: () {})),
                  Expanded(child: SessionSearchPage(now: searchNow)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '登录');
    await settleSearch(tester);
    expect(find.byType(SearchResultTile), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}
