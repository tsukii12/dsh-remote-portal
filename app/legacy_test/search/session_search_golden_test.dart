// Golden screenshots of the session search page.
//
//   flutter test --update-goldens test/search/session_search_golden_test.dart

import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

Future<void> Function(WidgetTester) search(String query) => (tester) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(SessionSearchController.debounce);
  await tester.pump();
  // The keyboard is down once the search key was pressed.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 300));
};

void main() {
  // Title matches (one running, one current), a content-only hit with its
  // excerpt, and an archived match.
  goldenBoth(
    'session_search_results',
    () => SessionSearchPage(now: searchNow),
    overrides: () => [
      sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
      sessionContentSearchProvider.overrideWithValue(
        FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)}),
      ),
      currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
    ],
    before: search('登录'),
  );

  // Nothing found on a host whose content index is off (the stock profile).
  goldenBoth(
    'session_search_empty',
    () => SessionSearchPage(now: searchNow),
    overrides: () => [
      sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
      sessionContentSearchProvider.overrideWithValue(FakeContentSearch(error: searchDisabled)),
    ],
    before: search('webview 白屏'),
  );
}
