// What a share code carries (分享码, docs/design/share-codes.md): one plugin, or a
// profile bundle exported from an engine. Readers are strict about what may be
// installed from a link — public npm packages at an exact version, GitHub /
// https git at a ref, or an official bundle to switch on — and lenient about
// display text.

import 'package:dsh_client/dsh_client.dart' show isExactSemver;
import 'package:flutter/foundation.dart';

import 'settings_sanitizer.dart' show isShareableNamespace;

/// Body format version of plugins and profiles. A reader refuses bodies
/// newer than it knows.
const shareFormatVersion = 1;

/// Body kinds.
enum ShareKind {
  plugin,
  profile,

  /// A conversation to read and replay (`conversation_share.dart`): not a
  /// [SharePayload], nothing is installed from it.
  conversation;

  static ShareKind? parse(Object? value) => switch (value) {
    'plugin' => plugin,
    'profile' => profile,
    'conversation' => conversation,
    _ => null,
  };
}

/// Something in a share body is malformed or not allowed.
class ShareFormatException implements Exception {
  const ShareFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'ShareFormatException: $reason';
}

/// Where a shared plugin comes from.
enum PluginSourceKind {
  npm,
  github,
  git,

  /// An official optional bundle shipped with DSH: only switched on.
  official,
}

final _packageName = RegExp(r'^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$');
final _githubShorthand = RegExp(
  r'^github:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([A-Za-z0-9_./-]+)(&path:/[A-Za-z0-9_./@+-]+)?$',
);
final _gitHttps = RegExp(
  r'^git\+https://([A-Za-z0-9.-]+)/([A-Za-z0-9_./-]+?)(?:\.git)?#([A-Za-z0-9_./-]+)(&path:/[A-Za-z0-9_./@+-]+)?$',
);
final _integrity = RegExp(r'^sha(256|384|512)-[A-Za-z0-9+/]+={0,2}$');

bool isPackageName(String name) => name.length <= 214 && _packageName.hasMatch(name);

/// One shared plugin.
@immutable
class SharedPlugin {
  const SharedPlugin({
    required this.name,
    required this.source,
    this.spec,
    this.version,
    this.integrity,
    this.title,
    this.author,
    this.summary,
  });

  /// npm package name (the bundle name DSH lists it under).
  final String name;
  final PluginSourceKind source;

  /// What `pluginManager/installBundle` gets; null for [PluginSourceKind.official].
  final String? spec;

  /// Exact version (npm: required; git: informational).
  final String? version;

  /// npm `dist.integrity` at share time (`sha512-…`).
  final String? integrity;
  final String? title;
  final String? author;

  /// One line.
  final String? summary;

  String get displayTitle => (title?.trim().isNotEmpty ?? false) ? title!.trim() : name;

  /// `owner/repo` of a GitHub source; the host of another git source.
  String? get repository {
    final s = spec;
    if (s == null) return null;
    if (_githubShorthand.firstMatch(s) case final m?) return '${m.group(1)}/${m.group(2)}';
    if (_gitHttps.firstMatch(s) case final m?) {
      return m.group(1) == 'github.com' ? m.group(2)!.split('/').take(2).join('/') : m.group(1);
    }
    return null;
  }

  /// npm for a plain version; the git ref otherwise.
  String? get gitRef {
    final s = spec;
    if (s == null) return null;
    return (_githubShorthand.firstMatch(s) ?? _gitHttps.firstMatch(s))?.group(3);
  }

  /// Validates and builds; throws [ShareFormatException] for anything a link
  /// may not install.
  factory SharedPlugin.fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('plugin is not an object');
    final name = _str(json['name']);
    if (name == null || !isPackageName(name)) throw const ShareFormatException('bad plugin name');
    final sourceName = _str(json['source']);
    final source = PluginSourceKind.values.where((k) => k.name == sourceName).firstOrNull;
    if (source == null) throw const ShareFormatException('unknown plugin source');
    final spec = _str(json['spec']);
    final version = _str(json['version']);
    final integrity = _str(json['integrity']);
    switch (source) {
      case PluginSourceKind.npm:
        if (version == null || !isExactSemver(version)) throw const ShareFormatException('npm needs an exact version');
        if (spec != '$name@$version') throw const ShareFormatException('npm spec must be name@version');
        if (integrity != null && !_integrity.hasMatch(integrity)) throw const ShareFormatException('bad integrity');
      case PluginSourceKind.github:
        final ok =
            spec != null && (_githubShorthand.hasMatch(spec) || (_gitHttps.firstMatch(spec)?.group(1) == 'github.com'));
        if (!ok) throw const ShareFormatException('not a GitHub spec');
      case PluginSourceKind.git:
        if (spec == null || !_gitHttps.hasMatch(spec)) throw const ShareFormatException('not an https git spec');
      case PluginSourceKind.official:
        if (spec != null) throw const ShareFormatException('official bundles carry no spec');
    }
    return SharedPlugin(
      name: name,
      source: source,
      spec: spec,
      version: version != null && isExactSemver(version) ? version : null,
      integrity: source == PluginSourceKind.npm ? integrity : null,
      title: _text(json['title'], 80),
      author: _text(json['author'], 80),
      summary: _text(json['summary'], 200),
    );
  }

  /// From an installed bundle's `pnpm add` spec ([PluginBundle.source]):
  /// null for local paths, tarballs and anything else a link can't carry.
  static SharedPlugin? fromInstalledSource({
    required String name,
    required String? source,
    required String? version,
    String? title,
    String? author,
    String? summary,
    String? integrity,
  }) {
    final s = source?.trim();
    if (s == null || s.isEmpty) return null;
    PluginSourceKind? kind;
    String? spec;
    if (_githubShorthand.hasMatch(s)) {
      kind = PluginSourceKind.github;
      spec = s;
    } else if (_gitHttps.firstMatch(s) case final m?) {
      kind = m.group(1) == 'github.com' ? PluginSourceKind.github : PluginSourceKind.git;
      spec = s;
    } else if (version != null && isExactSemver(version) && _isRegistrySpec(s, name)) {
      kind = PluginSourceKind.npm;
      spec = '$name@$version';
    }
    if (kind == null) return null;
    return SharedPlugin(
      name: name,
      source: kind,
      spec: spec,
      version: version != null && isExactSemver(version) ? version : null,
      integrity: kind == PluginSourceKind.npm ? integrity : null,
      title: _text(title, 80),
      author: _text(author, 80),
      summary: _text(summary, 200),
    );
  }

  /// `name`, `name@range`, `npm:name@range`: a registry dependency.
  static bool _isRegistrySpec(String spec, String name) {
    final s = spec.startsWith('npm:') ? spec.substring(4) : spec;
    if (s == name) return true;
    if (!s.startsWith('$name@')) return false;
    final range = s.substring(name.length + 1);
    // A version or range, not a URL / path / alias of something else.
    return RegExp(r'^[\w.^~<>=|* -]+$').hasMatch(range);
  }

  SharedPlugin copyWith({String? integrity, String? author}) => SharedPlugin(
    name: name,
    source: source,
    spec: spec,
    version: version,
    integrity: integrity ?? this.integrity,
    title: title,
    author: author ?? this.author,
    summary: summary,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'source': source.name,
    'spec': ?spec,
    'version': ?version,
    'integrity': ?integrity,
    'title': ?title,
    'author': ?author,
    'summary': ?summary,
  };

  @override
  bool operator ==(Object other) =>
      other is SharedPlugin && other.name == name && other.source == source && other.spec == spec;

  @override
  int get hashCode => Object.hash(name, source, spec);
}

/// An agent preset a profile's plugins add.
@immutable
class SharedPreset {
  const SharedPreset({required this.id, this.name, this.bundle});

  factory SharedPreset.fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('preset is not an object');
    final id = _str(json['id']);
    if (id == null || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id)) throw const ShareFormatException('bad preset');
    return SharedPreset(id: id, name: _text(json['name'], 60), bundle: _str(json['bundle']));
  }

  final String id;
  final String? name;

  /// The shared plugin that declares it.
  final String? bundle;

  String get displayName => name ?? id;

  Map<String, Object?> toJson() => {'id': id, 'name': ?name, 'bundle': ?bundle};
}

/// A user skill: its folder's text files (`SKILL.md` first).
@immutable
class SharedSkill {
  const SharedSkill({required this.name, required this.files});

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  static final _path = RegExp(r'^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+){0,3}$');

  factory SharedSkill.fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('skill is not an object');
    final name = _str(json['name']);
    if (name == null || !_name.hasMatch(name)) throw const ShareFormatException('bad skill name');
    final files = json['files'];
    if (files is! Map || files.isEmpty || files.length > maxFiles) throw const ShareFormatException('bad skill files');
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in files.entries) {
      if (key is! String || !isSafePath(key) || value is! String) throw const ShareFormatException('bad skill file');
      if (value.length > maxFileChars) throw const ShareFormatException('skill file too large');
      out[key] = value;
    }
    if (!out.containsKey('SKILL.md')) throw const ShareFormatException('skill without SKILL.md');
    return SharedSkill(name: name, files: out);
  }

  static const maxFiles = 12;
  static const maxFileChars = 64 * 1024;

  /// A relative path inside the skill folder: no `..`, no hidden segments.
  static bool isSafePath(String path) =>
      _path.hasMatch(path) && !path.split('/').any((s) => s == '..' || s == '.' || s.startsWith('.'));

  final String name;

  /// Relative path → text.
  final Map<String, String> files;

  Map<String, Object?> toJson() => {'name': name, 'files': files};
}

/// A shared body.
@immutable
sealed class SharePayload {
  const SharePayload();

  ShareKind get kind;

  Map<String, Object?> toJson();

  /// Validates a decoded body.
  static SharePayload fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('body is not an object');
    final v = json['v'];
    if (v is! int || v < 1) throw const ShareFormatException('no format version');
    if (v > shareFormatVersion) throw const ShareFormatException('newer format');
    return switch (ShareKind.parse(json['kind'])) {
      ShareKind.plugin => PluginShare(SharedPlugin.fromJson(json['plugin'])),
      ShareKind.profile => ProfileShare.fromJson(json),
      // Read with ConversationShare.fromJson (the share-code host routes it).
      ShareKind.conversation => throw const ShareFormatException('conversation'),
      null => throw const ShareFormatException('unknown kind'),
    };
  }
}

final class PluginShare extends SharePayload {
  const PluginShare(this.plugin);

  final SharedPlugin plugin;

  @override
  ShareKind get kind => ShareKind.plugin;

  @override
  Map<String, Object?> toJson() => {'v': shareFormatVersion, 'kind': 'plugin', 'plugin': plugin.toJson()};
}

final class ProfileShare extends SharePayload {
  const ProfileShare({
    this.name,
    this.created,
    this.settings = const {},
    this.plugins = const [],
    this.presets = const [],
    this.skills = const [],
    this.agentsMd,
  });

  static final _ns = RegExp(r'^[A-Za-z0-9._:@/-]{1,80}$');
  static const maxAgentsMdChars = 64 * 1024;

  factory ProfileShare.fromJson(Map<Object?, Object?> json) {
    final settings = <String, Map<String, Object?>>{};
    final rawSettings = json['settings'];
    if (rawSettings != null) {
      if (rawSettings is! Map) throw const ShareFormatException('settings is not an object');
      for (final MapEntry(:key, :value) in rawSettings.entries) {
        if (key is! String || !_ns.hasMatch(key) || value is! Map) throw const ShareFormatException('bad settings');
        if (!isShareableNamespace(key)) continue;
        settings[key] = {
          for (final MapEntry(key: k, value: v) in value.entries)
            if (k is String) k: v,
        };
      }
    }
    List<T> list<T>(Object? raw, T Function(Object?) read, int max) {
      if (raw == null) return const [];
      if (raw is! List || raw.length > max) throw const ShareFormatException('bad list');
      return [for (final item in raw) read(item)];
    }

    final agentsMd = json['agentsMd'];
    if (agentsMd != null && (agentsMd is! String || agentsMd.length > maxAgentsMdChars)) {
      throw const ShareFormatException('bad AGENTS.md');
    }
    final created = _str(json['created']);
    return ProfileShare(
      name: _text(json['name'], 40),
      created: created == null ? null : DateTime.tryParse(created),
      settings: settings,
      plugins: list(json['plugins'], SharedPlugin.fromJson, 64),
      presets: list(json['presets'], SharedPreset.fromJson, 64),
      skills: list(json['skills'], SharedSkill.fromJson, 32),
      agentsMd: agentsMd is String && agentsMd.trim().isNotEmpty ? agentsMd : null,
    );
  }

  final String? name;
  final DateTime? created;

  /// Namespace → the profile's own (user-layer) values.
  final Map<String, Map<String, Object?>> settings;
  final List<SharedPlugin> plugins;
  final List<SharedPreset> presets;
  final List<SharedSkill> skills;
  final String? agentsMd;

  bool get isEmpty => settings.isEmpty && plugins.isEmpty && presets.isEmpty && skills.isEmpty && agentsMd == null;

  @override
  ShareKind get kind => ShareKind.profile;

  @override
  Map<String, Object?> toJson() => {
    'v': shareFormatVersion,
    'kind': 'profile',
    'name': ?name,
    if (created != null) 'created': created!.toUtc().toIso8601String(),
    if (settings.isNotEmpty) 'settings': settings,
    if (plugins.isNotEmpty) 'plugins': [for (final p in plugins) p.toJson()],
    if (presets.isNotEmpty) 'presets': [for (final p in presets) p.toJson()],
    if (skills.isNotEmpty) 'skills': [for (final s in skills) s.toJson()],
    'agentsMd': ?agentsMd,
  };
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// Display text: trimmed, one line, at most [max] characters.
String? _text(Object? v, int max) {
  if (v is! String) return null;
  final t = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}
