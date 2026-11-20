/// App version as the update checker compares it.
///
/// Semver (`1.2.0`, `1.3.0-beta.2`) plus the Android build number from
/// `pubspec.yaml` (`1.2.0+7` → versionName `1.2.0`, versionCode 7). A leading
/// `v` (git tag) is accepted; a missing patch reads as `.0`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.preRelease = const [], this.build});

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated pre-release identifiers: `beta.2` → `['beta', '2']`.
  final List<String> preRelease;

  /// Numeric build number (Android versionCode); null when absent or not a number.
  final int? build;

  static final _pattern = RegExp(r'^[vV]?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$');

  static AppVersion? tryParse(String? input) {
    final m = _pattern.firstMatch(input?.trim() ?? '');
    if (m == null) return null;
    final pre = m.group(4);
    if (pre != null && pre.split('.').any((p) => p.isEmpty)) return null;
    return AppVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3) ?? '0'),
      preRelease: pre == null ? const [] : pre.split('.'),
      build: int.tryParse(m.group(5) ?? ''),
    );
  }

  /// Same version with [build] replaced (the native versionCode).
  AppVersion withBuild(int? build) => AppVersion(major, minor, patch, preRelease: preRelease, build: build);

  bool get isPreRelease => preRelease.isNotEmpty;

  /// `1.3.0-beta.2`, without the build number: what release names and asset
  /// file names use.
  String get name => '$major.$minor.$patch${isPreRelease ? '-${preRelease.join('.')}' : ''}';

  /// Semver precedence (a pre-release sorts before its release). Build numbers
  /// only break a tie when both sides have one: a tag `v1.2.0` is the same
  /// release as an installed `1.2.0+7`.
  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    final pre = _comparePreRelease(preRelease, other.preRelease);
    if (pre != 0) return pre;
    if (build != null && other.build != null) return build!.compareTo(other.build!);
    return 0;
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  static int _comparePreRelease(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1);
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = int.tryParse(a[i]);
      final y = int.tryParse(b[i]);
      final c = switch ((x, y)) {
        (final x?, final y?) => x.compareTo(y),
        (_?, null) => -1, // numeric identifiers sort before alphanumeric ones
        (null, _?) => 1,
        (null, null) => a[i].compareTo(b[i]),
      };
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0 && build == other.build;

  @override
  int get hashCode => Object.hash(name, build);

  @override
  String toString() => build == null ? name : '$name+$build';
}
