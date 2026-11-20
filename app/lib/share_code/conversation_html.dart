// 「导出为网页」: one `.html` file that opens anywhere, offline, and replays the
// conversation. The page is the shared viewer (site/share/viewer.js) inlined at
// build time (replay_viewer.g.dart); the conversation file goes inside it as
// JSON.

import 'replay_viewer.g.dart';

/// MIME type of the exported page.
const conversationHtmlMime = 'text/html';

/// The self-contained page for a conversation file's text ([fileText], what
/// `encodeConversationFile` wrote).
String conversationHtml(String fileText, {required String title}) {
  // JSON inside <script>: no `<` may end the block early (`\u003c` is the
  // same character to JSON.parse).
  final data = fileText
      .trim()
      .replaceAll('<', r'\u003c')
      .replaceAll('>', r'\u003e')
      .replaceAll('&', r'\u0026')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return replayViewerPage
      .replaceFirst('__DSHGO_TITLE__', '${_escape(title)} · DSH Go')
      .replaceFirst('__DSHGO_DATA__', data);
}

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
