// System back on a web page (WebViewPage), one press one step, the way it
// goes on a native page: what the page has open first, then the page's own
// history, then out — off the page, or (as the app's home, 网页模式) out of
// the app.
//
// DSH Web keeps where the person is in component state, never in its URL or
// history (0.2.1-rc.4: no pushState anywhere), so the WebView's history alone
// let back skip straight past an open settings sheet and leave the app. The
// page itself is asked first (`assets/web/dsh_web_back.js`): its dialogs and
// menus, popovers, the app's drawer, the right panel, a plugin's page, a full
// page in the conversation's place.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where one press of back went.
enum WebBackOutcome {
  /// The page took a step of its own (`window.__dshAppBack()`).
  page,

  /// The WebView went back in its history.
  history,

  /// Off the page, or out of the app.
  leave,

  /// The page went away while the press waited its turn: nothing to do.
  dropped,
}

/// What a page answers about back.
abstract final class WebBack {
  /// Asks the page to take one step back; answers what it did.
  static const script = "window.__dshAppBack ? window.__dshAppBack() : 'none'";

  /// Most a page gets to answer: one that doesn't (a renderer stuck in a long
  /// task) is past going back inside, and the press goes on without it.
  static const answerTimeout = Duration(seconds: 2);

  /// Whether [answer] (from `runJavaScriptReturningResult(script)`) says the
  /// page took the step. Android hands a string back JSON-quoted; anything
  /// but a known step (none, an error, nothing) is no.
  static bool tookStep(Object? answer) {
    var value = answer;
    if (value is String && value.length >= 2 && value.startsWith('"')) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        return false;
      }
    }
    return value is String && steps.contains(value);
  }

  /// The steps `dsh_web_back.js` takes ('none' is not one).
  @visibleForTesting
  static const steps = {'layer', 'popup', 'drawer', 'panel', 'page', 'chat'};
}

/// Runs presses of back one at a time, each to the end, so a press never
/// sees the half-done step of the one before it (a page asked twice for the
/// same open dialog), and one press is one step.
class WebBackDispatcher {
  WebBackDispatcher({
    required this.askPage,
    required this.canGoBack,
    required this.goBack,
    required this.leave,
    this.isActive,
    this.answerTimeout = WebBack.answerTimeout,
  });

  /// Runs [WebBack.script] in the page; null when the page can't be asked
  /// (still loading, an error page, not DSH Web).
  final Future<Object?>? Function() askPage;
  final Future<bool> Function() canGoBack;
  final Future<void> Function() goBack;
  final Future<void> Function() leave;

  /// False once the page is gone: presses still queued are dropped.
  final bool Function()? isActive;

  final Duration answerTimeout;

  Future<void> _last = Future<void>.value();

  /// One press of back; completes with where it went once it got there.
  Future<WebBackOutcome> press() {
    final done = _last.then((_) => _step());
    _last = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  Future<WebBackOutcome> _step() async {
    if (!(isActive?.call() ?? true)) return WebBackOutcome.dropped;
    final asked = askPage();
    if (asked != null) {
      Object? answer;
      try {
        answer = await asked.timeout(answerTimeout);
      } catch (_) {
        // No answer in time, or a page without a DOM: as if it had nothing.
      }
      if (WebBack.tookStep(answer)) return WebBackOutcome.page;
      if (!(isActive?.call() ?? true)) return WebBackOutcome.dropped;
    }
    var history = false;
    try {
      history = await canGoBack();
    } catch (_) {}
    if (!(isActive?.call() ?? true)) return WebBackOutcome.dropped;
    if (history) {
      await goBack();
      return WebBackOutcome.history;
    }
    await leave();
    return WebBackOutcome.leave;
  }
}
