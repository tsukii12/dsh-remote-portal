// Card sites' character pages (docs/design/roleplay-ui.md §1, 从链接导入):
// a page on Chub or RisuRealm is read through the site's own download, so
// what is pasted can be the page rather than the file. Only sites whose
// downloads were checked against the live site (2026-11-12) are here; any
// other link is fetched as it is.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;

enum TavernCardSite { chub, risu }

/// [uri] as a character page on a site the App downloads from, with the
/// site's id for it; null for anything else (a file's link, a lorebook, a
/// search page).
({TavernCardSite site, String id})? tavernCardSiteOf(Uri uri) {
  final host = uri.host.toLowerCase();
  final path = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (const {'chub.ai', 'www.chub.ai', 'venus.chub.ai', 'characterhub.org', 'www.characterhub.org'}.contains(host)) {
    // chub.ai/characters/<creator>/<name>, or the short chub.ai/<creator>/<name>.
    final rest = path.isNotEmpty && path.first.toLowerCase() == 'characters' ? path.skip(1).toList() : path;
    if (rest.length < 2 || (rest.length == path.length && path.length != 2)) return null;
    if (const {'lorebooks', 'presets', 'users', 'search', 'chats'}.contains(rest.first.toLowerCase())) return null;
    return (site: TavernCardSite.chub, id: '${rest[0]}/${rest[1]}');
  }
  if (host == 'realm.risuai.net' && path.length == 2 && path.first == 'character') {
    final id = path[1];
    if (RegExp(r'^[0-9a-fA-F-]+$').hasMatch(id)) return (site: TavernCardSite.risu, id: id);
  }
  return null;
}

/// Why a site's card could not be had.
class TavernCardSiteError implements Exception {
  const TavernCardSiteError({this.status});

  /// The site's HTTP status, when it answered with one other than 200.
  final int? status;
}

/// The card behind a site's page, as a file the engine imports, and a name
/// for it. Throws [TavernCardSiteError] when the site says no, or what it
/// gives is not a card; a failing connection throws as [client] does.
Future<({Uint8List bytes, String fileName})> downloadTavernSiteCard(
  http.Client client,
  ({TavernCardSite site, String id}) page,
) async {
  switch (page.site) {
    case TavernCardSite.risu:
      final response = await client.get(
        Uri.https('realm.risuai.net', '/api/v1/download/png-v3/${page.id}', {'non_commercial': 'true'}),
      );
      if (response.statusCode != 200) throw TavernCardSiteError(status: response.statusCode);
      return (bytes: response.bodyBytes, fileName: '${page.id}.png');
    case TavernCardSite.chub:
      final response = await client.get(
        Uri.https('api.chub.ai', '/api/characters/${page.id}', {'full': 'true'}),
        headers: const {'Accept': 'application/json'},
      );
      if (response.statusCode != 200) throw TavernCardSiteError(status: response.statusCode);
      final Object? node;
      try {
        node = (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>)['node'];
      } on FormatException {
        throw const TavernCardSiteError();
      } on TypeError {
        throw const TavernCardSiteError();
      }
      if (node is! Map<String, Object?> || node['definition'] is! Map<String, Object?>) {
        throw const TavernCardSiteError();
      }
      final card = chubCardOf(node, creator: page.id.split('/').first);
      final json = Uint8List.fromList(utf8.encode(jsonEncode(card)));
      final name = (card['data']! as Map<String, Object?>)['name'];
      final fileName = '${name is String && name.trim().isNotEmpty ? name.trim() : page.id.split('/').last}.png';
      // The site's picture becomes the card's; without it the card still comes.
      final picture = node['max_res_url'];
      if (picture is String && picture.startsWith('https://')) {
        try {
          final image = await client.get(Uri.parse(picture));
          if (image.statusCode == 200) {
            const codec = CardCodec();
            final decoded = codec.decode(json);
            return (bytes: codec.encode(TavernCard(json: decoded.json, png: image.bodyBytes)), fileName: fileName);
          }
        } on Object {
          // Not a PNG, or not there: the card alone.
        }
      }
      return (bytes: json, fileName: fileName.replaceFirst(RegExp(r'\.png$'), '.json'));
  }
}

/// A V2 card from Chub's description of a character. Chub keeps the card's
/// description under `personality` and its own page text under
/// `description`, so the fields cross over.
Map<String, Object?> chubCardOf(Map<String, Object?> node, {required String creator}) {
  final d = node['definition']! as Map<String, Object?>;
  String text(String key) => switch (d[key]) {
    final String s => s,
    _ => '',
  };
  return {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': {
      'name': switch (d['name']) {
        final String s when s.trim().isNotEmpty => s,
        _ => switch (node['name']) {
          final String s => s,
          _ => '',
        },
      },
      'description': text('personality'),
      'personality': text('tavern_personality'),
      'scenario': text('scenario'),
      'first_mes': text('first_message'),
      'mes_example': text('example_dialogs'),
      'creator_notes': text('description'),
      'system_prompt': text('system_prompt'),
      'post_history_instructions': text('post_history_instructions'),
      'alternate_greetings': [
        for (final g in switch (d['alternate_greetings']) {
          final List<Object?> l => l,
          _ => const <Object?>[],
        })
          if (g is String) g,
      ],
      'tags': [
        for (final t in switch (node['topics']) {
          final List<Object?> l => l,
          _ => const <Object?>[],
        })
          if (t is String) t,
      ],
      'creator': creator,
      'character_version': '',
      if (d['embedded_lorebook'] case final Map<String, Object?> book) 'character_book': book,
      'extensions': switch (d['extensions']) {
        final Map<String, Object?> e => e,
        _ => const <String, Object?>{},
      },
    },
  };
}
