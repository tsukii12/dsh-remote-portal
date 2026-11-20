import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

class PortalDirectoryListing extends DirectoryLevel {
  PortalDirectoryListing({required super.path, required String? parent,
    required this.roots, required super.entries, required super.truncated})
      : super(home: roots.isEmpty ? '' : roots.first.path, crumbs: [
          if (parent != null && parent.isNotEmpty) DirectoryEntry(name: parent, path: parent),
          DirectoryEntry(name: path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? path, path: path),
        ]);

  final List<DirectoryEntry> roots;
}

class PortalFileSystem {
  const PortalFileSystem(this.connection);
  final DshConnection connection;
  static const _prefix = '/yuremote/fs';

  Future<PortalDirectoryListing> browse([String? path]) async {
    final response = await connection.get(_prefix,
      query: path == null || path.isEmpty ? null : {'path': path},
      followRedirects: false, maxResponseBytes: 2 * 1024 * 1024);
    final listing = _object(_decode(response)['listing']);
    return PortalDirectoryListing(
      path: _path(listing), parent: listing['parent'] as String?,
      roots: _entries(listing['roots']), entries: _entries(listing['entries']),
      truncated: listing['truncated'] == true,
    );
  }

  Future<String> mkdir(String parent, String name) async {
    final response = await connection.postBytes('$_prefix/mkdir',
      utf8.encode(jsonEncode({'parent': parent, 'name': name})),
      contentType: 'application/json', followRedirects: false, maxResponseBytes: 65536);
    return _path(_object(_decode(response)['created']));
  }

  static Map<String, dynamic> _decode(DshHttpResponse response) {
    if (response.statusCode == 401 || response.statusCode == 403 ||
        (response.statusCode >= 300 && response.statusCode < 400)) {
      throw DshHttpException(response.statusCode, 'Portal filesystem request refused');
    }
    Object? decoded;
    try { decoded = jsonDecode(response.text); } on FormatException {
      throw const DshProtocolException('Invalid portal filesystem response');
    }
    final value = _object(decoded);
    if (value['ok'] == false) {
      throw DshRemoteException(value['code'] as String? ?? 'portal/fs-failed', 'Portal filesystem request failed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DshHttpException(response.statusCode, 'Portal filesystem request failed');
    }
    if (value['ok'] != true) throw const DshProtocolException('Invalid portal filesystem response');
    return value;
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) throw const DshProtocolException('Invalid portal filesystem response');
    return value;
  }

  static String _path(Map<String, dynamic> value) {
    final path = value['path'];
    if (path is! String || path.isEmpty) throw const DshProtocolException('Missing portal folder path');
    return path;
  }

  static List<DirectoryEntry> _entries(Object? value) {
    if (value is! List) throw const DshProtocolException('Missing portal folder entries');
    return [for (final raw in value) DirectoryEntry.fromJson({..._object(raw), 'path': _path(_object(raw))})];
  }
}
