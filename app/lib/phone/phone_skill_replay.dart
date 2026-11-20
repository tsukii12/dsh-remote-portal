/// A current PackageManager choice supplied by private native inspection.
class PhoneSkillReplayApp {
  const PhoneSkillReplayApp({required this.packageName, required this.uid, required this.label});
  final String packageName;
  final int uid;
  final String label;
}

class PhoneSkillReplayInspection {
  const PhoneSkillReplayInspection._({this.revision, this.summary, this.apps = const [], this.reason});
  const PhoneSkillReplayInspection.unavailable() : this._(reason: 'unavailable');
  final String? revision;
  final String? summary;
  final List<PhoneSkillReplayApp> apps;
  final String? reason;
  bool get available => revision != null;

  factory PhoneSkillReplayInspection.parse(Object? raw) {
    if (raw is! Map) return const PhoneSkillReplayInspection.unavailable();
    if (raw['kind'] == 'rejected') {
      return PhoneSkillReplayInspection._(reason: raw['reason'] == 'unsupported' ? 'unsupported' : 'unavailable');
    }
    final revision = raw['revision'], summary = raw['summary'], apps = raw['apps'];
    if (raw['kind'] != 'available' || revision is! String || revision.length != 32 || !_revision.hasMatch(revision) ||
        summary is! String || apps is! List || apps.isEmpty) {
      return const PhoneSkillReplayInspection.unavailable();
    }
    final parsed = <PhoneSkillReplayApp>[];
    final seen = <(String, int)>{};
    for (final app in apps) {
      if (app is! Map) return const PhoneSkillReplayInspection.unavailable();
      final pkg = app['packageName'], uid = app['uid'], label = app['label'];
      if (pkg is! String || pkg.isEmpty || uid is! int || uid < 0 || uid > 2147483647 ||
          label is! String || !seen.add((pkg, uid))) {
        return const PhoneSkillReplayInspection.unavailable();
      }
      parsed.add(PhoneSkillReplayApp(packageName: pkg, uid: uid, label: label));
    }
    return PhoneSkillReplayInspection._(revision: revision, summary: summary, apps: List.unmodifiable(parsed));
  }
}

class PhoneSkillReplayReady {
  const PhoneSkillReplayReady._(this.invocation, this.revision);
  final String invocation;
  final String revision;
  static PhoneSkillReplayReady? parse(Object? raw) {
    if (raw is! Map || raw['kind'] != 'ready') return null;
    final invocation = raw['invocation'], revision = raw['revision'], names = raw['parameterNames'];
    if (invocation is! String || invocation.length != 32 || !_revision.hasMatch(invocation) || revision is! String || revision.length != 32 ||
        !_revision.hasMatch(revision) || names is! List || names.isNotEmpty) {
      return null;
    }
    return PhoneSkillReplayReady._(invocation, revision);
  }
}

final _revision = RegExp(r'^[a-f0-9]{32}$');
