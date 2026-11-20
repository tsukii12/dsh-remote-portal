// One way into 对话详情 for every entry (the header's
// title pill, the progress strip, 全部功能), whatever form the window gives
// it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/adaptive_layout_state.dart';
import '../../../state/sessions_state.dart' show currentSessionProvider;
import '../../session/session_tab.dart';
import 'adaptive_layout.dart';
import 'adaptive_scaffold.dart';
import 'detail_sheet.dart';

/// Shows 对话详情 of [sessionId]:
///
/// - wide window, the open conversation: the panel beside the chat — shown
///   (back on the chat first, if a page covers it), or folded away when
///   [toggle] and it already shows;
/// - medium window: the two-height sheet ([sheet]);
/// - phone: a page ([page]).
///
/// [tab] picks the tab first; it is shared by all three forms.
void openAdaptiveDetail(
  BuildContext context, {
  required String sessionId,
  SessionTab? tab,
  bool toggle = false,
  required WidgetBuilder page,
  required WidgetBuilder sheet,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  if (tab != null) {
    container.read(sessionDetailTabProvider.notifier).select(tab);
  }
  final current = container.read(currentSessionProvider) == sessionId;
  final prefs = container.read(layoutPrefsProvider);
  final layout =
      AdaptiveChrome.layoutOf(context) ??
      AdaptiveLayout.resolve(
        window: MediaQuery.sizeOf(context),
        padding: MediaQuery.paddingOf(context),
        hasSession: true,
        sidebarOpen: prefs.sidebarOpen,
        panelOpen: prefs.panelOpen,
      );
  final controller = container.read(layoutPrefsProvider.notifier);
  final navigator = Navigator.of(context);
  switch (layout.detail) {
    case DetailPresentation.panel when current:
      // The panel lives beside the chat: uncover it.
      navigator.popUntil((route) => route.isFirst);
      final fold = toggle && layout.panelShown && tab == null;
      controller.setPanelOpen(!fold);
    case DetailPresentation.page:
      navigator.push(MaterialPageRoute<void>(builder: page));
    case DetailPresentation.sheet || DetailPresentation.panel:
      showDetailSheet(context, builder: sheet, onWide: current ? () => controller.setPanelOpen(true) : null);
  }
}
