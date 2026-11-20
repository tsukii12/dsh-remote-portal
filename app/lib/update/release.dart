import 'update_config.dart';
import 'version.dart';

/// The APK flavors the app ships (Gradle `abi` dimension).
enum ApkFlavor {
  arm64('arm64-v8a'),
  x64('x86_64');

  const ApkFlavor(this.abi);

  /// Android ABI name.
  final String abi;

  /// From Flutter's `appFlavor` (`--flavor arm64`).
  static ApkFlavor? fromName(String? name) => values.where((f) => f.name == name).firstOrNull;

  /// From an ABI or native library directory name (`arm64-v8a`, `arm64`, `x86_64`).
  static ApkFlavor? fromAbi(String? abi) => switch (abi) {
    'arm64-v8a' || 'arm64' => arm64,
    'x86_64' => x64,
    _ => null,
  };
}

/// File name of the APK for [version] and [flavor]: `dsh-go-1.2.0-arm64.apk`.
/// No build number: GitHub rewrites `+` in asset names.
String apkAssetName(AppVersion version, ApkFlavor flavor) => 'dsh-go-${version.name}-${flavor.name}.apk';

final _apkAssetPattern = RegExp(r'^dsh-go-(.+)-(arm64|x64)\.apk$');

/// What a manifest may name a file: it becomes a path in the download
/// directory, so nothing that climbs out of it.
final _fileName = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._+-]*$');

/// One downloadable APK.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.size, this.sha256});

  final String name;
  final Uri url;

  /// Bytes; null when the source didn't say.
  final int? size;

  /// Lowercase hex; null until resolved (GitHub API without a digest).
  final String? sha256;

  ReleaseAsset withSha256(String sha256) => ReleaseAsset(name: name, url: url, size: size, sha256: sha256);
}

/// A `DSHDLT01` patch (lib/update/delta.dart) that builds a release's APK from
/// one installed APK. It sits next to that APK: same release, same mirrors.
class ReleasePatch {
  const ReleasePatch({
    required this.from,
    required this.name,
    required this.size,
    required this.sha256,
    this.fromVersion,
  });

  /// SHA-256 of the APK it applies to (the installed `base.apk`).
  final String from;

  /// What version that APK is; nothing depends on it.
  final String? fromVersion;
  final String name;

  /// Bytes of the patch file, and its SHA-256.
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'from': from,
    'fromVersion': ?fromVersion,
    'name': name,
    'size': size,
    'sha256': sha256,
  };

  /// An entry of `update.json`'s `patches`; null when it is incomplete.
  static ReleasePatch? tryParse(Object? json) {
    if (json is! Map) return null;
    final from = normalizeSha256(json['from']);
    final sha256 = normalizeSha256(json['sha256']);
    final name = json['name'];
    final size = json['size'];
    if (from == null || sha256 == null || name is! String || !_fileName.hasMatch(name) || size is! int) return null;
    final version = json['fromVersion'];
    return ReleasePatch(
      from: from,
      name: name,
      size: size,
      sha256: sha256,
      fromVersion: version is String ? version : null,
    );
  }
}

/// The latest release as one source described it.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.apks,
    this.notes = '',
    this.notesByLocale = const {},
    this.title,
    this.publishedAt,
    this.pageUrl,
    this.checksumsUrl,
    this.patches = const {},
  });

  final AppVersion version;
  final String tag;
  final Map<ApkFlavor, ReleaseAsset> apks;

  /// Markdown.
  final String notes;

  /// The same notes per language (`zh`, `en`), when the source splits them
  /// (the beta channel's `update.json`).
  final Map<String, String> notesByLocale;
  final String? title;
  final DateTime? publishedAt;
  final Uri? pageUrl;

  /// `SHA256SUMS` of this release, used when an asset carries no digest.
  final Uri? checksumsUrl;

  /// Deltas to each flavor's APK, by the installed APK they start from.
  final Map<ApkFlavor, List<ReleasePatch>> patches;

  ReleaseAsset? apkFor(ApkFlavor? flavor) => flavor == null ? null : apks[flavor];

  /// [flavor]'s patch from the installed APK hashing to [installed].
  ReleasePatch? patchFor(ApkFlavor? flavor, String? installed) =>
      installed == null ? null : patches[flavor]?.where((p) => p.from == installed).firstOrNull;

  /// This release with [flavor]'s APK under [sha256] (one taken from
  /// `SHA256SUMS`, or kept from an earlier answer). Unchanged without that APK.
  ReleaseInfo withApkSha256(ApkFlavor flavor, String sha256) {
    final apk = apks[flavor];
    if (apk == null) return this;
    return ReleaseInfo(
      version: version,
      tag: tag,
      apks: {...apks, flavor: apk.withSha256(sha256)},
      notes: notes,
      notesByLocale: notesByLocale,
      title: title,
      publishedAt: publishedAt,
      pageUrl: pageUrl,
      checksumsUrl: checksumsUrl,
      patches: patches,
    );
  }

  /// `update.json` (schema 1): what the release script writes and what a
  /// self-hosted feed serves. Also how the last offer is cached on the phone.
  Map<String, Object?> toManifestJson() => {
    'schema': 1,
    'version': version.toString(),
    'tag': tag,
    'title': ?title,
    if (publishedAt case final at?) 'publishedAt': at.toUtc().toIso8601String(),
    'notes': notes,
    if (notesByLocale.isNotEmpty) 'notesByLocale': notesByLocale,
    if (pageUrl case final url?) 'page': url.toString(),
    'assets': {
      for (final MapEntry(key: flavor, value: asset) in apks.entries)
        flavor.name: {'name': asset.name, 'url': asset.url.toString(), 'size': ?asset.size, 'sha256': ?asset.sha256},
    },
    if (patches.isNotEmpty)
      'patches': {
        for (final MapEntry(key: flavor, value: list) in patches.entries)
          flavor.name: [for (final p in list) p.toJson()],
      },
  };
}

/// Normalizes a SHA-256 as GitHub (`sha256:…`) or `sha256sum` writes it.
/// Null when it isn't 64 hex digits.
String? normalizeSha256(Object? value) {
  if (value is! String) return null;
  var hex = value.trim().toLowerCase();
  if (hex.startsWith('sha256:')) hex = hex.substring(7);
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}

/// Parses a GitHub `releases/latest` body. Throws [FormatException] when it
/// isn't a usable release (draft, unparsable tag).
ReleaseInfo parseGithubRelease(Object? json) {
  if (json is! Map) throw const FormatException('release is not an object');
  if (json['draft'] == true) throw const FormatException('draft release');
  final tag = json['tag_name'];
  final version = tag is String ? AppVersion.tryParse(tag) : null;
  if (version == null) throw FormatException('unrecognised tag: $tag');
  final apks = <ApkFlavor, ReleaseAsset>{};
  Uri? checksums;
  for (final asset in (json['assets'] as List?)?.whereType<Map>() ?? const <Map>[]) {
    final name = asset['name'];
    final url = Uri.tryParse(asset['browser_download_url'] as String? ?? '');
    if (name is! String || url == null || !url.hasScheme) continue;
    if (name == checksumsName) {
      checksums = url;
      continue;
    }
    final match = _apkAssetPattern.firstMatch(name);
    final flavor = ApkFlavor.fromName(match?.group(2));
    if (flavor == null) continue;
    apks[flavor] = ReleaseAsset(
      name: name,
      url: url,
      size: (asset['size'] as num?)?.toInt(),
      sha256: normalizeSha256(asset['digest']),
    );
  }
  final title = json['name'];
  return ReleaseInfo(
    version: version,
    tag: tag as String,
    apks: apks,
    // Release bodies edited on github.com come with CRLF line ends.
    notes: (json['body'] as String? ?? '').replaceAll('\r\n', '\n'),
    title: title is String && title.trim().isNotEmpty ? title.trim() : null,
    publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
    pageUrl: Uri.tryParse(json['html_url'] as String? ?? ''),
    checksumsUrl: checksums,
  );
}

/// Parses an `update.json` manifest ([ReleaseInfo.toManifestJson]). Relative
/// asset URLs resolve against [base] (the manifest's own URL); a missing URL
/// means the GitHub release asset for the tag. Files named anything but a
/// plain file name, and incomplete patch entries, are left out.
ReleaseInfo parseUpdateManifest(Object? json, {Uri? base}) {
  if (json is! Map) throw const FormatException('manifest is not an object');
  final schema = json['schema'];
  if (schema is num && schema.toInt() > 1) throw FormatException('unsupported manifest schema $schema');
  final version = AppVersion.tryParse(json['version'] as String?);
  if (version == null) throw FormatException('unrecognised version: ${json['version']}');
  final tag = json['tag'] as String? ?? 'v${version.name}';
  final apks = <ApkFlavor, ReleaseAsset>{};
  final assets = json['assets'];
  if (assets is Map) {
    for (final MapEntry(:key, :value) in assets.entries) {
      final flavor = ApkFlavor.fromName(key as String?);
      if (flavor == null || value is! Map) continue;
      final name = value['name'] as String? ?? apkAssetName(version, flavor);
      final raw = value['url'] as String?;
      final url = raw == null ? githubReleaseAsset(tag, name) : (base?.resolve(raw) ?? Uri.tryParse(raw));
      if (url == null || !url.hasScheme || !_fileName.hasMatch(name)) continue;
      apks[flavor] = ReleaseAsset(
        name: name,
        url: url,
        size: (value['size'] as num?)?.toInt(),
        sha256: normalizeSha256(value['sha256']),
      );
    }
  }
  final page = json['page'] as String?;
  return ReleaseInfo(
    version: version,
    tag: tag,
    apks: apks,
    notes: json['notes'] as String? ?? '',
    notesByLocale: {
      if (json['notesByLocale'] case final Map<String, Object?> byLocale)
        for (final MapEntry(:key, :value) in byLocale.entries)
          if (value is String && value.trim().isNotEmpty) key: value,
    },
    title: json['title'] as String?,
    publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? ''),
    pageUrl: page == null ? null : Uri.tryParse(page),
    patches: {
      if (json['patches'] case final Map byFlavor)
        for (final MapEntry(:key, :value) in byFlavor.entries)
          if (ApkFlavor.fromName(key as String?) case final flavor? when value is List)
            flavor: [for (final entry in value) ?ReleasePatch.tryParse(entry)],
    },
  );
}

/// Reads `sha256sum` output (`<hex>  <name>` or `<hex> *<name>`) into name → hex.
Map<String, String> parseSha256Sums(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final m = RegExp(r'^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line);
    if (m != null) out[m.group(2)!] = m.group(1)!.toLowerCase();
  }
  return out;
}

/// The release notes in [language] (`zh`, `en`): the source's own split
/// first, else that language's section of notes written as
/// `### 中文 … ### English …` (the changelog's form); Chinese when there is
/// nothing in [language]; the notes as they are when they have no sections.
String releaseNotesFor(ReleaseInfo release, String language) {
  final lang = language == 'en' ? 'en' : 'zh';
  final split = release.notesByLocale;
  if (split[lang]?.trim() case final text? when text.isNotEmpty) return text;
  if (split['zh']?.trim() case final text? when text.isNotEmpty) return text;
  final sections = _notesSections(release.notes);
  return (sections[lang] ?? sections['zh'] ?? release.notes).trim();
}

/// `### 中文` / `### English` sections of [notes]; empty without them.
Map<String, String> _notesSections(String notes) {
  final heading = RegExp(r'^#{2,3}[ \t]*(中文|English)[ \t]*$', multiLine: true);
  final marks = heading.allMatches(notes).toList();
  if (marks.isEmpty) return const {};
  return {
    for (final (i, m) in marks.indexed)
      if (notes.substring(m.end, i + 1 < marks.length ? marks[i + 1].start : notes.length).trim() case final body
          when body.isNotEmpty)
        m.group(1) == 'English' ? 'en' : 'zh': body,
  };
}
