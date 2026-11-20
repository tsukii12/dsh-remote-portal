// A card script's UI request (the engine's host.interact, from /input,
// /buttons, /popup, /echo and /setinput): its kind, its fields read as the
// contract gives them, and the answer the app sends back. The app shows
// these itself, never in the card's page (lib/ui/tavern/tavern_interact_view.dart).

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

enum TavernInteractKind { input, buttons, popup, echo, setInput }

/// [kind] as the engine names it; null for one not known here.
TavernInteractKind? tavernInteractKind(Object? kind) => switch (kind) {
  'input' => TavernInteractKind.input,
  'buttons' => TavernInteractKind.buttons,
  'popup' => TavernInteractKind.popup,
  'echo' => TavernInteractKind.echo,
  'setInput' => TavernInteractKind.setInput,
  _ => null,
};

/// How the person left it: answered, turned down (取消), or closed some
/// other way (a tap beside it, back).
enum TavernInteractStatus { submitted, cancelled, dismissed }

/// What the app answers: [text] for input (what was written, '' too), echo
/// and setInput (what was shown or set); [buttonIndex] and its [label] for
/// buttons.
final class TavernInteractAnswer {
  const TavernInteractAnswer(this.status, {this.text, this.buttonIndex, this.label});

  final TavernInteractStatus status;
  final String? text;
  final int? buttonIndex;
  final String? label;

  Map<String, Object?> toJson() => {
    'status': status.name,
    if (text != null) 'text': text,
    if (buttonIndex != null) 'buttonIndex': buttonIndex,
    if (label != null) 'label': label,
  };

  @override
  bool operator ==(Object other) =>
      other is TavernInteractAnswer &&
      other.status == status &&
      other.text == text &&
      other.buttonIndex == buttonIndex &&
      other.label == label;

  @override
  int get hashCode => Object.hash(status, text, buttonIndex, label);

  @override
  String toString() => 'TavernInteractAnswer(${toJson()})';
}

/// A request's fields, with the contract's defaults where one is missing:
/// input, buttons and popup carry HTML (textKind 'html'), echo plain text;
/// Markdown only when asked for; input's box 4 rows; nothing wide or large;
/// popup scrolls. [okButton] is null when not given, for the app's own word.
final class TavernInteractFields {
  const TavernInteractFields({
    required this.text,
    required this.html,
    this.markdown = false,
    this.defaultValue = '',
    this.rows = 4,
    this.wide = false,
    this.large = false,
    this.okButton,
    this.buttonLabels = const [],
    this.scroll = true,
    this.title,
    this.severity = 'info',
    this.awaitDismissal = false,
  });

  factory TavernInteractFields.of(TavernInteractKind kind, Map<String, Object?> fields) {
    String? string(String key) => switch (fields[key]) {
      final String s => s,
      _ => null,
    };
    bool flag(String key, bool otherwise) => switch (fields[key]) {
      final bool b => b,
      _ => otherwise,
    };
    return TavernInteractFields(
      text: string('text') ?? '',
      html: switch (fields['textKind']) {
        'html' => true,
        'plain' => false,
        _ => kind != TavernInteractKind.echo && kind != TavernInteractKind.setInput,
      },
      markdown: flag('renderMarkdown', false),
      defaultValue: string('defaultValue') ?? '',
      rows: switch (fields['rows']) {
        final int n when n > 0 => n,
        _ => 4,
      },
      wide: flag('wide', false),
      large: flag('large', false),
      okButton: switch (string('okButton')) {
        final s? when s.isNotEmpty => s,
        _ => null,
      },
      buttonLabels: switch (fields['buttonLabels']) {
        final List<Object?> labels => [for (final l in labels) '$l'],
        _ => const [],
      },
      scroll: flag('scroll', true),
      title: switch (string('title')) {
        final s? when s.trim().isNotEmpty => s,
        _ => null,
      },
      severity: string('severity') ?? 'info',
      awaitDismissal: flag('awaitDismissal', false),
    );
  }

  final String text;
  final bool html;
  final bool markdown;
  final String defaultValue;
  final int rows;
  final bool wide;
  final bool large;
  final String? okButton;
  final List<String> buttonLabels;
  final bool scroll;
  final String? title;
  final String severity;
  final bool awaitDismissal;

  /// [text] as it reads: HTML brought down to its words, line breaks kept.
  String get shown => html ? tavernInteractPlain(text) : text;
}

const _blocks = {
  'p', 'div', 'section', 'article', 'header', 'footer', 'blockquote', 'pre', 'ul', 'ol', 'li', 'table', 'tr', //
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'details', 'summary', 'figure', 'figcaption',
};

/// [source] (HTML) as plain words: parsed apart (nothing in it loads or
/// runs); scripts and styles dropped; a block and <br> a line of its own; a
/// list item marked •; runs of spaces one; no more than one empty line.
String tavernInteractPlain(String source) {
  final out = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      out.write(node.text);
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (const {'script', 'style', 'template', 'noscript'}.contains(tag)) return;
      if (tag == 'br') {
        out.write('\n');
        return;
      }
      final block = _blocks.contains(tag);
      if (block) out.write('\n');
      if (tag == 'li') out.write('• ');
      for (final child in node.nodes) {
        walk(child);
      }
      if (block) out.write('\n');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(html.parseFragment(source));
  return out
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t ]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
