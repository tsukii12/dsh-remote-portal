// Reads a Discourse post's cooked HTML into blocks the forum page draws
// natively.
//
// Why cooked HTML and not the raw Markdown: Discourse's own extensions are
// resolved on the server and exist only in the cooked form — `[quote]` becomes
// `<aside class="quote">` with the quoted user's avatar, `@name` a mention
// link, `:emoji:` an <img alt=":name:">, a bare link on its own line a
// server-fetched onebox card, `upload://` short URLs real (CDN) image URLs
// with sizes, plus polls, local dates, hashtags and plugin markup. Rebuilding
// all of that from raw would mean re-implementing Discourse's pipeline (and
// an extra request per post: topic JSON carries only cooked).
//
// So: prose (paragraphs, headings, lists, code, tables) is turned back into
// Markdown and drawn by the app's own MarkdownBody, exactly like a chat reply;
// quotes, oneboxes, images, share codes, details and polls become their own
// blocks with native widgets.

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../l10n/l10n.dart';
import '../../share_code/share_link.dart';
import '../discourse_client.dart' show forumResolve;
import '../emoji.dart';

sealed class CookedBlock {
  const CookedBlock();
}

/// Prose for MarkdownBody.
final class CookedMarkdown extends CookedBlock {
  const CookedMarkdown(this.markdown);
  final String markdown;
}

/// `[quote="name, post:3, topic:12"]`.
final class CookedQuote extends CookedBlock {
  const CookedQuote({
    this.username,
    this.avatarUrl,
    this.topicId,
    this.postNumber,
    this.topicTitle,
    this.body = const [],
  });

  final String? username;
  final Uri? avatarUrl;
  final int? topicId;
  final int? postNumber;

  /// Set when the quote comes from another topic.
  final String? topicTitle;
  final List<CookedBlock> body;
}

/// A link preview Discourse fetched for a bare URL.
final class CookedOnebox extends CookedBlock {
  const CookedOnebox({required this.url, this.source, this.title, this.description, this.imageUrl});

  final Uri url;

  /// The site (`github.com/discourse/discourse`).
  final String? source;
  final String? title;
  final String? description;
  final Uri? imageUrl;
}

final class CookedImage extends CookedBlock {
  const CookedImage({required this.src, this.fullSrc, this.alt = '', this.width, this.height});

  /// The (optimized) picture to draw.
  final Uri src;

  /// The original, for the full-screen view.
  final Uri? fullSrc;
  final String alt;
  final int? width;
  final int? height;

  double? get aspectRatio => width != null && height != null && width! > 0 && height! > 0 ? width! / height! : null;
}

/// A dsh-go share link: drawn as an install card.
final class CookedShare extends CookedBlock {
  const CookedShare(this.link, {this.label});

  final ShareLink link;

  /// The link's own text when the author gave one.
  final String? label;
}

final class CookedDetails extends CookedBlock {
  const CookedDetails({required this.summary, this.body = const []});
  final String summary;
  final List<CookedBlock> body;
}

/// A poll, a video or anything else best seen on the web.
final class CookedEmbed extends CookedBlock {
  const CookedEmbed({required this.kind, this.url, this.label});

  final CookedEmbedKind kind;
  final Uri? url;
  final String? label;
}

enum CookedEmbedKind { poll, video, other }

/// Reads [cooked] (relative URLs resolve against [base]).
List<CookedBlock> parseCooked(String cooked, {required Uri base}) {
  final fragment = html.parseFragment(cooked);
  final reader = _Reader(base);
  reader.blocks(fragment.nodes);
  return reader.finish();
}

/// The share links in [cooked], in order (for a post's cards without
/// drawing it; tests).
List<ShareLink> shareLinksIn(String cooked, {required Uri base}) {
  final out = <ShareLink>[];
  void walk(List<CookedBlock> blocks) {
    for (final b in blocks) {
      switch (b) {
        case CookedShare(:final link):
          out.add(link);
        case CookedQuote(:final body) || CookedDetails(:final body):
          walk(body);
        default:
          break;
      }
    }
  }

  walk(parseCooked(cooked, base: base));
  return out;
}

class _Reader {
  _Reader(this.base);

  final Uri base;
  final _out = <CookedBlock>[];
  final _md = StringBuffer();

  /// Share links met inside the current paragraph, emitted after it.
  final _pendingShares = <CookedShare>[];

  List<CookedBlock> finish() {
    _flush();
    return _out;
  }

  void _flush() {
    final text = _md.toString().trim();
    _md.clear();
    if (text.isNotEmpty) _out.add(CookedMarkdown(text));
  }

  void _emit(CookedBlock block) {
    _flush();
    _out.add(block);
  }

  void _paragraph(String markdown) {
    final text = markdown.trim();
    if (text.isNotEmpty) {
      if (_md.isNotEmpty) _md.write('\n\n');
      _md.write(text);
    }
  }

  void _emitShares() {
    if (_pendingShares.isEmpty) return;
    final shares = List.of(_pendingShares);
    _pendingShares.clear();
    shares.forEach(_emit);
  }

  List<CookedBlock> _sub(List<dom.Node> nodes) {
    final reader = _Reader(base);
    reader.blocks(nodes);
    return reader.finish();
  }

  // ── Blocks ────────────────────────────────────────────────────────────────

  void blocks(List<dom.Node> nodes) {
    final inline = <dom.Node>[];
    void flushInline() {
      if (inline.isEmpty) return;
      _inlineRun(List.of(inline));
      inline.clear();
    }

    for (final node in nodes) {
      if (node is dom.Element && _isBlock(node)) {
        flushInline();
        _block(node);
      } else if (node is dom.Text || node is dom.Element) {
        inline.add(node);
      }
    }
    flushInline();
  }

  static const _blockTags = {
    'p', 'div', 'aside', 'blockquote', 'pre', 'ul', 'ol', 'table', 'hr', 'details', 'section', 'article', //
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figure', 'iframe', 'video', 'audio', 'header', 'footer',
  };

  static bool _isBlock(dom.Element e) => _blockTags.contains(e.localName);

  void _block(dom.Element e) {
    final tag = e.localName;
    final classes = e.classes;
    switch (tag) {
      case 'aside' when classes.contains('quote'):
        _emit(_quote(e));
      case 'aside' when classes.contains('onebox'):
        final href = _oneboxHref(e);
        final url = href == null ? null : forumResolve(base, href);
        final share = url == null ? null : ShareLink.parse(url);
        if (share != null) {
          _emit(CookedShare(share));
        } else if (url != null) {
          _emit(_onebox(e, url));
        }
      case 'aside':
        blocks(e.nodes);
      case 'div' when classes.contains('lightbox-wrapper'):
        final image = _lightbox(e);
        if (image != null) _emit(image);
      case 'div' when classes.contains('poll'):
        if (!_insidePoll(e)) _emit(CookedEmbed(kind: CookedEmbedKind.poll, label: _pollTitle(e)));
      case 'div' when classes.contains('youtube-onebox') || classes.contains('lazy-video-container'):
        _emit(CookedEmbed(kind: CookedEmbedKind.video, url: _videoUrl(e), label: e.attributes['data-video-title']));
      case 'div' when classes.contains('md-table'):
        blocks(e.nodes);
      case 'iframe' || 'video' || 'audio':
        final src = e.attributes['src'] ?? e.querySelector('source')?.attributes['src'];
        _emit(
          CookedEmbed(
            kind: tag == 'iframe' ? CookedEmbedKind.other : CookedEmbedKind.video,
            url: src == null ? null : forumResolve(base, src),
          ),
        );
      case 'p':
        _inlineRun(e.nodes);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(tag!.substring(1));
        final text = _inline(e.nodes).trim();
        if (text.isNotEmpty) _paragraph('${'#' * level} ${text.replaceAll('\n', ' ')}');
        _emitShares();
      case 'pre':
        _paragraph(_fence(e));
      case 'ul' || 'ol':
        _paragraph(_list(e, 0));
        _emitShares();
      case 'table':
        _paragraph(_table(e));
        _emitShares();
      case 'hr':
        _paragraph('---');
      case 'blockquote':
        final body = _sub(e.nodes);
        _quoteMarkdown(body);
      case 'details':
        final summary = e.querySelector('summary');
        final rest = [
          for (final n in e.nodes)
            if (n != summary) n,
        ];
        _emit(
          CookedDetails(summary: summary == null ? appL10n.commonDetails : _plain(summary).trim(), body: _sub(rest)),
        );
      default:
        blocks(e.nodes);
    }
  }

  /// A plain `<blockquote>`: Markdown parts get `> `, the rest stays as is.
  void _quoteMarkdown(List<CookedBlock> body) {
    for (final block in body) {
      if (block is CookedMarkdown) {
        _paragraph(block.markdown.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n'));
      } else {
        _emit(block);
      }
    }
  }

  /// A paragraph's worth of inline nodes; images and share links inside it
  /// split it into blocks.
  void _inlineRun(List<dom.Node> nodes) {
    final buffer = <dom.Node>[];
    void flushText() {
      if (buffer.isEmpty) return;
      final text = _escapeLineStarts(_inline(buffer));
      buffer.clear();
      _paragraph(text);
      _emitShares();
    }

    for (final node in nodes) {
      if (node is dom.Element) {
        final image = _standaloneImage(node);
        if (image != null) {
          flushText();
          _emit(image);
          continue;
        }
        if (node.localName == 'div' || node.localName == 'aside') {
          flushText();
          _block(node);
          continue;
        }
      }
      buffer.add(node);
    }
    flushText();
  }

  /// An image that should stand alone (not an emoji, not an avatar).
  CookedImage? _standaloneImage(dom.Element e) {
    if (e.classes.contains('lightbox-wrapper')) return _lightbox(e);
    if (e.localName == 'a' && e.classes.contains('lightbox')) return _lightbox(e);
    if (e.localName == 'img' && !_isEmoji(e) && !_isAvatar(e)) return _image(e, null);
    if (e.localName == 'a') {
      final children = e.children;
      if (children.length == 1 &&
          children.first.localName == 'img' &&
          !_isEmoji(children.first) &&
          e.text.trim().isEmpty) {
        return _image(children.first, e.attributes['href']);
      }
    }
    return null;
  }

  static bool _isEmoji(dom.Element e) => e.classes.contains('emoji');
  static bool _isAvatar(dom.Element e) =>
      e.classes.contains('avatar') || e.classes.contains('onebox-avatar-inline') || e.classes.contains('site-icon');

  CookedImage? _lightbox(dom.Element e) {
    final img = e.localName == 'img' ? e : e.querySelector('img');
    if (img == null) return null;
    final anchor = e.localName == 'a' ? e : e.querySelector('a.lightbox');
    return _image(img, anchor?.attributes['href']);
  }

  CookedImage? _image(dom.Element img, String? full) {
    final src = img.attributes['src'] ?? img.attributes['data-src'];
    if (src == null || src.isEmpty || src.startsWith('data:')) return null;
    return CookedImage(
      src: forumResolve(base, src),
      fullSrc: full == null || full.isEmpty ? null : forumResolve(base, full),
      alt: (img.attributes['alt'] ?? '').trim(),
      width: int.tryParse(img.attributes['width'] ?? ''),
      height: int.tryParse(img.attributes['height'] ?? ''),
    );
  }

  CookedQuote _quote(dom.Element e) {
    final title = e.querySelector('.title');
    final avatar = title?.querySelector('img.avatar')?.attributes['src'];
    final topicLink = title?.querySelector('a');
    final quoted = e.querySelector('blockquote');
    final username =
        e.attributes['data-username'] ?? _plain(title ?? dom.Element.tag('span')).replaceAll(':', '').trim();
    return CookedQuote(
      username: username.isEmpty ? null : username,
      avatarUrl: avatar == null ? null : forumResolve(base, avatar),
      topicId: int.tryParse(e.attributes['data-topic'] ?? ''),
      postNumber: int.tryParse(e.attributes['data-post'] ?? ''),
      topicTitle: topicLink == null ? null : _plain(topicLink).trim(),
      body: _sub(quoted?.nodes ?? e.nodes.where((n) => n != title).toList()),
    );
  }

  static String? _oneboxHref(dom.Element e) =>
      e.attributes['data-onebox-src'] ??
      e.querySelector('header a')?.attributes['href'] ??
      e.querySelector('a')?.attributes['href'];

  CookedOnebox _onebox(dom.Element e, Uri url) {
    final source = e.querySelector('header a');
    final body = e.querySelector('article') ?? e;
    dom.Element? heading;
    for (final tag in const ['h3', 'h4', 'h2', 'h1']) {
      heading = body.querySelector(tag);
      if (heading != null) break;
    }
    final paragraph = body.querySelector('p');
    final image = body
        .querySelectorAll('img')
        .where((img) => !_isEmoji(img) && !_isAvatar(img) && (img.attributes['src'] ?? '').isNotEmpty)
        .firstOrNull;
    String? clean(String? s) {
      final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
      return t == null || t.isEmpty ? null : replaceEmojiShortcodes(t);
    }

    return CookedOnebox(
      url: url,
      source: clean(source?.text) ?? url.host,
      title: clean(heading?.text),
      description: clean(paragraph?.text),
      imageUrl: image == null ? null : forumResolve(base, image.attributes['src']!),
    );
  }

  static bool _insidePoll(dom.Element e) {
    for (var p = e.parent; p != null; p = p.parent) {
      if (p.classes.contains('poll')) return true;
    }
    return false;
  }

  String? _pollTitle(dom.Element e) {
    final title = e.querySelector('.poll-title')?.text.trim();
    return title == null || title.isEmpty ? null : title;
  }

  Uri? _videoUrl(dom.Element e) {
    final id = e.attributes['data-video-id'] ?? e.attributes['data-youtube-id'];
    final provider = e.attributes['data-provider-name'] ?? 'youtube';
    if (id != null && provider == 'youtube') return Uri.parse('https://www.youtube.com/watch?v=$id');
    if (id != null && provider == 'vimeo') return Uri.parse('https://vimeo.com/$id');
    final href = e.querySelector('a')?.attributes['href'];
    return href == null ? null : forumResolve(base, href);
  }

  // ── Markdown pieces ───────────────────────────────────────────────────────

  String _fence(dom.Element pre) {
    final code = pre.querySelector('code');
    final text = (code ?? pre).text.replaceAll(RegExp(r'\n$'), '');
    var language = '';
    for (final c in code?.classes ?? const <String>{}) {
      if (c.startsWith('lang-')) language = c.substring(5);
      if (c.startsWith('language-')) language = c.substring(9);
    }
    if (const {'auto', 'nohighlight', 'plaintext', 'text', 'txt'}.contains(language)) language = '';
    var fence = '```';
    while (text.contains(fence)) {
      fence += '`';
    }
    return '$fence$language\n$text\n$fence';
  }

  String _list(dom.Element list, int depth) {
    final ordered = list.localName == 'ol';
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final indent = '   ' * depth;
    final lines = <String>[];
    for (final item in list.children.where((c) => c.localName == 'li')) {
      final own = <dom.Node>[];
      final nested = <dom.Element>[];
      for (final n in item.nodes) {
        if (n is dom.Element && (n.localName == 'ul' || n.localName == 'ol')) {
          nested.add(n);
        } else if (n is dom.Element && n.localName == 'p') {
          if (own.isNotEmpty) own.add(dom.Text(' '));
          own.addAll(n.nodes);
        } else {
          own.add(n);
        }
      }
      final marker = ordered ? '${number++}.' : '-';
      final text = _inline(own).trim().replaceAll('\n', '\n$indent   ');
      lines.add('$indent$marker ${text.isEmpty ? '​' : text}');
      for (final sub in nested) {
        lines.add(_list(sub, depth + 1));
      }
    }
    return lines.join('\n');
  }

  String _table(dom.Element table) {
    final rows = <List<String>>[];
    var header = <String>[];
    for (final tr in table.querySelectorAll('tr')) {
      final cells = [
        for (final cell in tr.children.where((c) => c.localName == 'td' || c.localName == 'th'))
          _inline(cell.nodes).replaceAll('\n', ' ').replaceAll('|', r'\|').trim(),
      ];
      final inHead = tr.parent?.localName == 'thead' || tr.children.every((c) => c.localName == 'th');
      if (inHead && header.isEmpty && rows.isEmpty) {
        header = cells;
      } else {
        rows.add(cells);
      }
    }
    // A table with an empty header row (common in Discourse "info" tables)
    // reads better with its first row as the header.
    if (header.every((c) => c.isEmpty) && rows.isNotEmpty) header = rows.removeAt(0);
    final width = [header.length, for (final r in rows) r.length].fold(0, (a, b) => a > b ? a : b);
    if (width == 0) return '';
    List<String> pad(List<String> r) => [...r, for (var i = r.length; i < width; i++) ''];
    String line(List<String> r) => '| ${pad(r).map((c) => c.isEmpty ? ' ' : c).join(' | ')} |';
    return [line(header), '|${List.filled(width, ' --- ').join('|')}|', for (final r in rows) line(r)].join('\n');
  }

  /// Inline nodes → Markdown.
  String _inline(List<dom.Node> nodes) {
    final out = StringBuffer();
    for (final node in nodes) {
      out.write(_inlineNode(node));
    }
    // Collapse runs of spaces HTML would collapse, but keep hard breaks.
    return out
        .toString()
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r' *\\\n *'), '\\\n')
        .replaceAll(RegExp(r'(\\\n)+$'), '');
  }

  String _inlineNode(dom.Node node) {
    if (node is dom.Text) {
      final text = node.text.replaceAll(RegExp(r'\s+'), ' ');
      _findShareText(text);
      return _escape(text);
    }
    if (node is! dom.Element) return '';
    final e = node;
    String inner() => _inline(e.nodes);
    switch (e.localName) {
      case 'br':
        return '\\\n';
      case 'strong' || 'b':
        return _wrap(inner(), '**');
      case 'em' || 'i':
        return _wrap(inner(), '*');
      case 'del' || 's' || 'strike':
        return _wrap(inner(), '~~');
      case 'code' || 'kbd':
        return _codeSpan(e.text);
      case 'sup' || 'sub' || 'mark':
        final text = inner().trim();
        return text.isEmpty ? '' : '<${e.localName}>$text</${e.localName}>';
      case 'img':
        if (_isEmoji(e)) {
          final name = e.attributes['title'] ?? e.attributes['alt'] ?? '';
          return emojiFor(name) ?? _escape(name);
        }
        return _escape(e.attributes['alt'] ?? '');
      case 'svg':
        return '';
      case 'a':
        return _link(e);
      case 'span' when e.classes.contains('discourse-local-date'):
        return _escape(e.text.trim());
      case 'span' when e.classes.contains('hashtag-icon-placeholder'):
        return '';
      case 'ul' || 'ol':
        return '\n${_list(e, 0)}\n';
      default:
        return inner();
    }
  }

  String _link(dom.Element a) {
    final href = a.attributes['href'];
    if (href == null || href.isEmpty || href.startsWith('#')) return _inline(a.nodes);
    final url = forumResolve(base, href);
    final share = ShareLink.parse(url);
    final label = _inline(a.nodes).trim();
    if (share != null) {
      final plain = a.text.trim();
      _pendingShares.add(CookedShare(share, label: plain.isEmpty || plain == href ? null : plain));
      return '';
    }
    if (url.scheme != 'http' && url.scheme != 'https' && url.scheme != 'mailto') return label;
    // Heading anchors and other empty links draw nothing.
    if (label.isEmpty) return '';
    final target = url.toString().replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29');
    return '[$label]($target)';
  }

  /// Share links written as plain text (not linkified).
  void _findShareText(String text) {
    if (!text.contains('share')) return;
    final link = ShareLink.find(text);
    if (link != null) _pendingShares.add(CookedShare(link));
  }

  static String _plain(dom.Element e) => e.text.replaceAll(RegExp(r'\s+'), ' ');

  static String _wrap(String text, String marker) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;
    final lead = text.startsWith(' ') ? ' ' : '';
    final trail = text.endsWith(' ') ? ' ' : '';
    return '$lead$marker$trimmed$marker$trail';
  }

  static String _codeSpan(String code) {
    final text = code.replaceAll('\n', ' ');
    if (text.isEmpty) return '';
    var ticks = '`';
    while (text.contains(ticks)) {
      ticks += '`';
    }
    final pad = text.startsWith('`') || text.endsWith('`') ? ' ' : '';
    return '$ticks$pad$text$pad$ticks';
  }

  static final _special = RegExp(r'([\\`*_\[\]<>#|~$])');

  static String _escape(String text) => text.replaceAllMapped(_special, (m) => '\\${m[1]}');

  /// Text that would start a list or heading at a line start.
  static String _escapeLineStarts(String text) =>
      text.replaceAllMapped(RegExp(r'(^|\\\n)(\s*)([-+=]|\d+[.)])(?=\s)', multiLine: true), (m) {
        final marker = m[3]!;
        final escaped = marker.length > 1
            ? '${marker.substring(0, marker.length - 1)}\\${marker[marker.length - 1]}'
            : '\\$marker';
        return '${m[1]}${m[2]}$escaped';
      });
}
