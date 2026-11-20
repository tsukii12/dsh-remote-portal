// The restore point a profile import leaves on the on-device engine, so 安全模式's
// 「恢复上次正常的配置」 undoes it.
//
// That feature restores the record native code keeps at
// `filesDir/runtime/lkg/lkg.json` (runtime/LastKnownGood.kt): the main
// profile's enabled bundles, installed packages with versions, and its
// settings layer (`cordis.patch.yml`). Native code writes it after a healthy
// two-minute run, from the profile the engine booted with. Right before an
// import we write the same record from the profile as it is now — so until
// the imported setup has itself run healthily after a restart, restoring
// brings back exactly what was there before the import. The format must stay
// in step with LastKnownGood.kt (`load` / `save`).
//
// Skills and AGENTS.md aren't part of that record: what an import replaces is
// copied under `/root/.dsh/backups/` (not a skill root).

import 'dart:convert';
import 'dart:io';

import 'guest_fs.dart';
import 'share_models.dart';

class RestorePoint {
  RestorePoint(this.fs);

  final GuestFs fs;

  /// `filesDir/runtime/lkg/lkg.json` (the rootfs is `filesDir/runtime/rootfs`).
  File get lkgFile => File('${fs.root.parent.path}/lkg/lkg.json');

  Directory get _profile => fs.dir('${GuestFs.dshHome}/profiles/web');

  /// Records the main profile as the last good one. False when there is no
  /// profile yet (nothing to come back to) or it can't be read.
  Future<bool> pinCurrentProfile({DateTime? now}) async {
    try {
      final pkg = File('${_profile.path}/package.json');
      if (!pkg.existsSync()) return false;
      final json = jsonDecode(pkg.readAsStringSync());
      if (json is! Map) return false;
      final dsh = json['dsh'];
      final profile = dsh is Map ? dsh['profile'] : null;
      final bundles = [
        if (profile is Map && profile['bundles'] is List)
          for (final b in profile['bundles'] as List)
            if (b is String) b,
      ];
      final depsJson = json['dependencies'];
      final deps = [
        if (depsJson is Map)
          for (final k in depsJson.keys)
            if (k is String) k,
      ];
      final versions = <String, String>{};
      for (final name in deps) {
        try {
          final manifest = jsonDecode(File('${_profile.path}/node_modules/$name/package.json').readAsStringSync());
          final version = manifest is Map ? manifest['version'] : null;
          if (version is String && version.isNotEmpty) versions[name] = version;
        } catch (_) {}
      }
      final patchFile = File('${_profile.path}/cordis.patch.yml');
      final patch = patchFile.existsSync() ? patchFile.readAsStringSync() : null;
      final record = {
        'at': (now ?? DateTime.now()).millisecondsSinceEpoch,
        'bundles': bundles,
        'deps': deps,
        'versions': versions,
        'patch': patch,
      };
      final target = lkgFile;
      target.parent.createSync(recursive: true);
      final tmp = File('${target.path}.share-tmp');
      tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(record)}\n', flush: true);
      tmp.renameSync(target.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `/root/.dsh/backups/share-import-<stamp>` for files an import replaces.
  String backupDir(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '${GuestFs.dshHome}/backups/share-import-$stamp';
  }

  /// Rechecks, backs up and replaces a skill without an async handoff.
  /// A rejected or failed backup must never reach the destructive write.
  void replaceSkill(String backup, SharedSkill skill) {
    final files = fs.readSkillForImport(skill.name);
    if (files != null) {
      final parent = fs.dir('$backup/skills');
      parent.createSync(recursive: true);
      final slot = fs.dir('$backup/skills/${skill.name}');
      if (parent.listSync(followLinks: false).any((entry) => entry.path == slot.path)) {
        throw const FileSystemException('skill backup already exists');
      }
      slot.createSync();
      for (final MapEntry(key: rel, value: bytes) in files.entries) {
        final target = File('${slot.path}/$rel');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes, flush: true);
      }
    }
    fs.writeSkill(skill);
  }

  /// Copies the original AGENTS.md bytes into a new directory beside [backup].
  Future<void> backupAgentsMd(String backup) async {
    final source = fs.file(GuestFs.importedAgentsMd);
    if (!source.existsSync()) return;
    final parent = fs.dir(backup).parent;
    parent.createSync(recursive: true);
    // Two imports may share the timestamp; each copy owns a fresh directory.
    final prefix = backup.substring(backup.lastIndexOf('/') + 1);
    final saved = parent.createTempSync('$prefix-');
    final target = File('${saved.path}/AGENTS.md');
    source.copySync(target.path);
  }
}
