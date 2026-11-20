// 故事书: a chat's story as a book to keep or pass on. The current path as it
// reads (hidden messages and system lines left out), as an EPUB for reading
// apps (微信读书, Apple 图书, …) or as plain text. The long image is drawn by
// the page (lib/ui/tavern/tavern_storybook_page.dart).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_markers.dart';

/// One line of the story: who said it and what.
class TavernStoryLine {
  const TavernStoryLine({required this.you, required this.speaker, required this.text, required this.at});

  final bool you;
  final String speaker;
  final String text;
  final DateTime at;
}

/// What a book is made of; the words around the story come from the caller,
/// in the reader's language.
class TavernStory {
  const TavernStory({required this.title, required this.byline, required this.lines, this.cover});

  /// The story as it reads: [messages] (oldest first) without hidden ones,
  /// system lines or empty ones; yours under [you].
  factory TavernStory.of(
    List<TavernMessage> messages, {
    required String title,
    required String byline,
    required String you,
    Uint8List? cover,
  }) => TavernStory(
    title: title,
    byline: byline,
    cover: cover,
    lines: [
      for (final m in messages)
        if (!m.hidden && m.role != TavernRole.system && m.text.trim().isNotEmpty)
          TavernStoryLine(
            you: m.role == TavernRole.user,
            speaker: m.role == TavernRole.user ? you : m.speaker,
            text: m.text,
            at: m.at,
          ),
    ],
  );

  final String title;

  /// Who is in it: 林晚 和 你.
  final String byline;
  final List<TavernStoryLine> lines;

  /// The character's picture (PNG or JPEG), for the cover.
  final Uint8List? cover;

  /// Lines per chapter.
  static const chapter = 40;

  /// `2026-11-09 – 2026-11-10`, or one day; null for an empty story.
  String? get dates {
    if (lines.isEmpty) return null;
    String day(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
    final first = day(lines.first.at);
    final last = day(lines.last.at);
    return first == last ? first : '$first – $last';
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

/// What a message reads as in a book: markup a card's frontend draws (HTML
/// tags) and expression markers taken out, its lines, blank ones dropped.
List<String> tavernStoryParagraphs(String text) => [
  for (final line in tavernStripMarkers(text).replaceAll(RegExp(r'<[^<>\n]+>'), '').split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// A paragraph as XHTML: *action* in italics, **this** in bold, the rest
/// escaped.
String tavernStoryXhtml(String paragraph) =>
    _escape(paragraph)
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => '<strong>${m[1]}</strong>')
        .replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => '<em>${m[1]}</em>');

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// The story as plain text: the title, who and when, then each line under its
/// speaker.
String buildTavernStoryText(TavernStory story, {required String madeWith}) {
  final out = StringBuffer()
    ..writeln(story.title)
    ..writeln()
    ..writeln([story.byline, ?story.dates].join(' · '));
  for (final line in story.lines) {
    out
      ..writeln()
      ..writeln('${line.speaker}：');
    for (final p in tavernStoryParagraphs(line.text)) {
      out.writeln(p);
    }
  }
  out
    ..writeln()
    ..writeln('—— $madeWith');
  return out.toString();
}

/// The words an EPUB needs besides the story.
class TavernBookWords {
  const TavernBookWords({
    required this.language,
    required this.contents,
    required this.chapter,
    required this.madeWith,
  });

  /// BCP 47: zh-CN, en.
  final String language;

  /// 目录.
  final String contents;

  /// 第 n 章.
  final String Function(int n) chapter;

  /// 用 DSH Go 酒馆写成.
  final String madeWith;
}

/// A fresh book identifier (a random UUID).
String tavernBookId([math.Random? random]) {
  final r = random ?? math.Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The story as an EPUB 3 (with an EPUB 2 table of contents for older
/// readers): a cover when there is a picture, a title page, then chapters of
/// [TavernStory.chapter] lines.
Uint8List buildTavernEpub(TavernStory story, TavernBookWords words, {required String id, required DateTime modified}) {
  final lang = words.language;
  final title = _escape(story.title);
  final cover = story.cover;
  final coverType = cover == null ? null : _imageType(cover);
  final chapters = <List<TavernStoryLine>>[
    for (var i = 0; i < story.lines.length; i += TavernStory.chapter)
      story.lines.sublist(i, math.min(i + TavernStory.chapter, story.lines.length)),
  ];
  final stamp = modified.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+'), '');

  String page(String heading, String body, {String? bodyClass}) =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="$lang" lang="$lang">
<head><title>${_escape(heading)}</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body${bodyClass == null ? '' : ' class="$bodyClass"'}>
$body
</body>
</html>
''';

  final files = <String, String>{
    'style.css': _bookCss,
    'title.xhtml': page(
      story.title,
      [
        '<h1 class="book">$title</h1>',
        '<p class="byline">${_escape(story.byline)}</p>',
        if (story.dates case final dates?) '<p class="dates">${_escape(dates)}</p>',
        '<p class="made">${_escape(words.madeWith)}</p>',
      ].join('\n'),
      bodyClass: 'title',
    ),
    if (coverType != null)
      'cover.xhtml': page(
        story.title,
        '<div class="cover"><img src="images/cover.${coverType.ext}" alt="$title"/></div>',
        bodyClass: 'cover',
      ),
    for (final (i, lines) in chapters.indexed)
      'chapter-${i + 1}.xhtml': page(
        words.chapter(i + 1),
        [
          '<h2>${_escape(words.chapter(i + 1))}</h2>',
          for (final line in lines)
            [
              '<div class="line${line.you ? ' you' : ''}">',
              '<p class="who">${_escape(line.speaker)}</p>',
              for (final p in tavernStoryParagraphs(line.text)) '<p>${tavernStoryXhtml(p)}</p>',
              '</div>',
            ].join('\n'),
        ].join('\n'),
      ),
    'nav.xhtml':
        '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang" lang="$lang">
<head><title>${_escape(words.contents)}</title></head>
<body>
<nav epub:type="toc" id="toc"><h1>${_escape(words.contents)}</h1>
<ol>
${[for (var i = 1; i <= chapters.length; i++) '<li><a href="chapter-$i.xhtml">${_escape(words.chapter(i))}</a></li>'].join('\n')}
</ol>
</nav>
</body>
</html>
''',
    'toc.ncx':
        '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="$lang">
<head><meta name="dtb:uid" content="urn:uuid:$id"/></head>
<docTitle><text>$title</text></docTitle>
<navMap>
${[for (var i = 1; i <= chapters.length; i++) '<navPoint id="n$i" playOrder="$i"><navLabel><text>${_escape(words.chapter(i))}</text></navLabel><content src="chapter-$i.xhtml"/></navPoint>'].join('\n')}
</navMap>
</ncx>
''',
  };

  final opf =
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="$lang">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">urn:uuid:$id</dc:identifier>
<dc:title>$title</dc:title>
<dc:creator>${_escape(story.byline)}</dc:creator>
<dc:language>$lang</dc:language>
<meta property="dcterms:modified">$stamp</meta>
${coverType == null ? '' : '<meta name="cover" content="cover-image"/>'}
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="css" href="style.css" media-type="text/css"/>
${coverType == null ? '' : '<item id="cover-image" href="images/cover.${coverType.ext}" media-type="${coverType.mime}" properties="cover-image"/>\n<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>'}
<item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
${[for (var i = 1; i <= chapters.length; i++) '<item id="c$i" href="chapter-$i.xhtml" media-type="application/xhtml+xml"/>'].join('\n')}
</manifest>
<spine toc="ncx">
${coverType == null ? '' : '<itemref idref="cover" linear="no"/>'}
<itemref idref="title"/>
${[for (var i = 1; i <= chapters.length; i++) '<itemref idref="c$i"/>'].join('\n')}
</spine>
</package>
''';

  final archive = Archive()
    // First and stored: how a reader knows it is an EPUB.
    ..add(ArchiveFile.noCompress('mimetype', 20, ascii.encode('application/epub+zip')))
    ..add(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
'''),
    )
    ..add(ArchiveFile.string('OEBPS/content.opf', opf));
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(ArchiveFile.bytes('OEBPS/$key', utf8.encode(value)));
  }
  if (cover != null && coverType != null) archive.add(ArchiveFile.bytes('OEBPS/images/cover.${coverType.ext}', cover));
  return ZipEncoder().encodeBytes(archive);
}

/// PNG or JPEG, from its first bytes; null for anything else.
({String ext, String mime})? _imageType(Uint8List bytes) {
  if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47) {
    return (ext: 'png', mime: 'image/png');
  }
  if (bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return (ext: 'jpg', mime: 'image/jpeg');
  }
  return null;
}

const _bookCss = '''
body { font-family: serif; line-height: 1.8; margin: 0 6%; }
h1, h2 { text-align: center; font-weight: bold; }
h2 { font-size: 1.2em; margin: 2.5em 0 2em; }
.title { text-align: center; }
.title .book { font-size: 1.8em; margin: 30% 0 1em; }
.title p { text-indent: 0; margin: .4em 0; }
.byline { font-size: 1.05em; }
.dates, .made { font-size: .85em; color: #888; }
.made { margin-top: 3em; }
.cover { text-align: center; margin: 0; padding: 0; }
.cover img { max-width: 100%; max-height: 100%; }
.line { margin: 0 0 1.5em; }
.line p { margin: 0 0 .5em; text-indent: 0; }
.line .who { font-size: .85em; font-weight: bold; color: #8a6440; margin-bottom: .3em; }
.line.you .who { color: #4f6890; }
em { font-style: italic; color: #666; }
''';
