// The diagnostics bundle: which files it holds, what they say, and that no
// key or token survives into any of them. Also the exporter (cache file,
// Downloads, share sheet) with fake Android ends.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_export.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'support/zip_reader.dart';

const _sk = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';
const _launch = 'Zx9kq_77-LaunchToken';

final _at = DateTime(2026, 10, 24, 15, 30, 12);

RuntimeStatus _status({bool crashed = true}) => RuntimeStatus(
  phase: crashed ? RuntimePhase.error : RuntimePhase.running,
  abi: 'arm64-v8a',
  bundledVersion: 'r4-dsh0.2.1-rc.2-node24.22.1-ubuntu24.04.5-4ae04eb76a4f',
  installedVersion: 'r4-dsh0.2.1-rc.2-node24.22.1-ubuntu24.04.5-4ae04eb76a4f',
  dshVersion: '0.2.1-rc.2',
  nodeVersion: '24.22.1',
  baseUrl: 'http://127.0.0.1:3080',
  token: _launch,
  error: crashed ? 'login failed: http://127.0.0.1:3080/?token=$_launch' : null,
  strikes: crashed ? 1 : 0,
  failure: crashed
      ? RuntimeFailure(
          kind: FailureKind.startupFailed,
          at: DateTime.utc(2026, 10, 24, 7, 29),
          exitCode: 1,
          summary: 'Error: plugin dsh-approval-gate failed to load (apiKey=$_sk)',
          suspects: const ['dsh-approval-gate'],
          recent: const ['dsh-approval-gate'],
          diagnostics: '/root/.dsh/startup-diagnostics.json',
          upSeconds: 3,
        )
      : null,
);

DiagnosticsSnapshot _snapshot({bool crashed = true}) => DiagnosticsSnapshot(
  at: _at,
  status: _status(crashed: crashed),
  settings: const AppSettings(apiKey: _sk, themeMode: ThemeMode.dark, phoneStorage: true, loaded: true),
  native: const NativeDiagnostics(
    app: {'versionName': '1.0.0', 'versionCode': 1, 'abi': 'arm64'},
    device: {
      'manufacturer': 'Xiaomi',
      'brand': 'Redmi',
      'model': '23113RKC6C',
      'android': '14',
      'sdkInt': 34,
      'abis': ['arm64-v8a'],
      'memoryMb': 11718,
      'freeStorageMb': 40211,
    },
    manifest: {
      'runtimeVersion': 'r4-dsh0.2.1-rc.2-node24.22.1-ubuntu24.04.5-4ae04eb76a4f',
      'dshVersion': '0.2.1-rc.2',
      'nodeVersion': '24.22.1',
      'ubuntuVersion': '24.04.5',
    },
  ),
  connection: const {'host': 'local', 'state': 'connected'},
  performance: const {
    'device': {
      'tier': 'low',
      'cached': true,
      'cpuMaxKhz': [1800000, null],
      'policyVersion': 1,
    },
    'thermal': {'status': 2, 'lightweight': true, 'listening': true},
    'preferences': {'mode': 'auto', 'blurOverride': null},
    'defaults': {'autoStartLocalDefault': false},
  },
  engineLog: [
    '[dsh-app] launching dsh web',
    'dsh web: http://127.0.0.1:3080/?token=$_launch',
    '\x1B[2m[gateway]\x1B[0m listening on 127.0.0.1:3080',
    '[llm] DEEPSEEK_API_KEY=$_sk',
    '[agent] turn finished · 2,431 tokens',
  ],
  failureLog: crashed ? ['Error: boom', 'Authorization: Bearer abcdef123456'] : const [],
);

Map<String, String> _unzip(List<int> bytes) => {
  for (final e in readZip(Uint8List.fromList(bytes))) e.name: utf8.decode(e.data),
};

void main() {
  test('file name: ASCII, sortable, to the second', () {
    expect(DiagnosticsBundle.fileName(_at), 'dsh-go-diagnostics-20261024-153012.zip');
  });

  group('contents', () {
    late Map<String, String> files;

    setUp(() => files = _unzip(DiagnosticsBundle.build(_snapshot())));

    test('the five files, in order', () {
      expect(files.keys, ['summary.json', 'settings.json', 'crash.json', 'engine.log', 'failure.log']);
    });

    test('no key or launch token anywhere', () {
      for (final MapEntry(:key, :value) in files.entries) {
        expect(value, isNot(contains(_launch)), reason: key);
        expect(value, isNot(contains('4c1f0e7b')), reason: key);
        expect(value, isNot(contains('abcdef123456')), reason: key);
      }
    });

    test('summary: versions, device, Android, runtime manifest, connection', () {
      final summary = jsonDecode(files['summary.json']!) as Map<String, Object?>;
      expect(summary['generatedAt'], _at.toUtc().toIso8601String());
      expect((summary['app']! as Map)['version'], AppInfo.version);
      expect((summary['app']! as Map)['versionName'], '1.0.0');
      expect((summary['device']! as Map)['android'], '14');
      expect((summary['device']! as Map)['model'], '23113RKC6C');
      final runtime = summary['runtime']! as Map;
      expect(runtime['dshVersion'], '0.2.1-rc.2');
      expect(runtime['phase'], 'error');
      expect(runtime['strikes'], 1);
      expect(runtime['error'], 'login failed: http://127.0.0.1:3080/?token=•••');
      expect(runtime.containsKey('token'), isFalse);
      expect((summary['manifest']! as Map)['ubuntuVersion'], '24.04.5');
      expect(summary['connection'], {'host': 'local', 'state': 'connected'});
    });

    test('settings: what is set, never the key', () {
      final settings = jsonDecode(files['settings.json']!) as Map<String, Object?>;
      expect(settings['hasApiKey'], isTrue);
      expect(settings['themeMode'], 'dark');
      expect(settings['phoneStorage'], isTrue);
      expect(settings['autoStartLocalExplicit'], isTrue);
      expect(settings.keys, isNot(contains('apiKey')));
    });

    test('performance facts, cache, overrides and thermal state survive the bundle', () {
      final summary = jsonDecode(files['summary.json']!) as Map<String, Object?>;
      expect(summary['performance'], _snapshot().performance);
    });

    test('crash: the native classification, masked', () {
      final crash = jsonDecode(files['crash.json']!) as Map<String, Object?>;
      final latest = crash['latest']! as Map;
      expect(latest['kind'], 'startupFailed');
      expect(latest['exitCode'], 1);
      expect(latest['suspects'], ['dsh-approval-gate']);
      expect(latest['summary'], 'Error: plugin dsh-approval-gate failed to load (apiKey=sk-•••)');
      expect(crash.containsKey('mainProfile'), isFalse);
    });

    for (final (name, input, expected) in [
      ('short key in parentheses', 'Error: boom (apiKey=x)', 'Error: boom (apiKey=•••)'),
      (
        'secret includes an inner closing parenthesis',
        'Error: boom (password=synthetic)tail)',
        'Error: boom (password=•••)',
      ),
      (
        'unwrapped secret includes a closing parenthesis',
        'Error: boom password=synthetic)tail',
        'Error: boom password=•••',
      ),
    ]) {
      test('crash and logs: $name', () {
        final snapshot = DiagnosticsSnapshot(
          at: _at,
          status: RuntimeStatus(
            phase: RuntimePhase.error,
            failure: RuntimeFailure(kind: FailureKind.startupFailed, at: _at, summary: input),
          ),
          settings: const AppSettings(loaded: true),
          engineLog: [input],
          failureLog: [input],
        );
        final exported = _unzip(DiagnosticsBundle.build(snapshot));
        final crash = jsonDecode(exported['crash.json']!) as Map<String, Object?>;
        expect((crash['latest']! as Map)['summary'], expected);
        expect(exported['engine.log'], '$expected\n');
        expect(exported['failure.log'], '$expected\n');
      });
    }

    test('logs: masked, colour stripped, ordinary lines intact', () {
      expect(
        files['engine.log'],
        '[dsh-app] launching dsh web\n'
        'dsh web: http://127.0.0.1:3080/?token=•••\n'
        '[gateway] listening on 127.0.0.1:3080\n'
        '[llm] DEEPSEEK_API_KEY=sk-•••\n'
        '[agent] turn finished · 2,431 tokens\n',
      );
      expect(files['failure.log'], 'Error: boom\nAuthorization: Bearer •••\n');
    });
  });

  test('without a crash there is no crash.json or failure.log', () {
    final files = _unzip(DiagnosticsBundle.build(_snapshot(crashed: false)));
    expect(files.keys, ['summary.json', 'settings.json', 'engine.log']);
  });

  test('the log keeps the newest lines only', () {
    final snapshot = DiagnosticsSnapshot(
      at: _at,
      status: _status(crashed: false),
      settings: const AppSettings(loaded: true),
      engineLog: [for (var i = 0; i < diagnosticsLogLines + 50; i++) 'line $i'],
    );
    final log = _unzip(DiagnosticsBundle.build(snapshot))['engine.log']!.trimRight().split('\n');
    expect(log, hasLength(diagnosticsLogLines));
    expect(log.first, 'line 50');
    expect(log.last, 'line ${diagnosticsLogLines + 49}');
  });

  group('exporter', () {
    late Directory cache;
    late _Files files;
    late List<ShareParams> shared;
    late List<DiagnosticsStep> steps;
    late DiagnosticsExporter exporter;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('dsh-diagnostics-');
      addTearDown(() => cache.deleteSync(recursive: true));
      files = _Files();
      shared = [];
      steps = [];
      exporter = DiagnosticsExporter(
        collect: (at) async => _snapshot(),
        files: files,
        share: (params) async {
          shared.add(params);
          return ShareResultStatus.success;
        },
        cacheRoot: () async => cache,
        clock: () => _at,
      );
    });

    test('build writes one bundle into the cache, replacing older ones', () async {
      File('${cache.path}/diagnostics/dsh-go-diagnostics-20261023-090000.zip')
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final file = await exporter.build(onStep: steps.add);
      expect(file.path, '${cache.path}/diagnostics/dsh-go-diagnostics-20261024-153012.zip');
      expect(Directory('${cache.path}/diagnostics').listSync().map((e) => e.uri.pathSegments.last), [
        'dsh-go-diagnostics-20261024-153012.zip',
      ]);
      expect(_unzip(file.readAsBytesSync()).keys, contains('engine.log'));
      expect(steps, [DiagnosticsStep.collecting, DiagnosticsStep.packing]);
    });

    test('save hands the ZIP to Downloads and says where', () async {
      final where = await exporter.saveToDownloads(onStep: steps.add);
      expect(where, 'Download/DSH-Go/dsh-go-diagnostics-20261024-153012.zip');
      expect(files.saved.single.name, 'dsh-go-diagnostics-20261024-153012.zip');
      expect(files.saved.single.mime, 'application/zip');
      expect(diagnosticsSavedText(where), '已存到 下载/DSH-Go/dsh-go-diagnostics-20261024-153012.zip');
      expect(steps.last, DiagnosticsStep.saving);
    });

    for (final seconds in [0, 1]) {
      test('a later build preserves the ZIP awaiting native save (offset $seconds)', () async {
        final held = _HeldFiles();
        DiagnosticsExporter make(String line, DateTime at) => DiagnosticsExporter(
          collect: (_) async => DiagnosticsSnapshot(
            at: at,
            status: _status(crashed: false),
            settings: const AppSettings(loaded: true),
            engineLog: [line],
          ),
          files: held,
          cacheRoot: () async => cache,
          clock: () => at,
        );
        final first = make('first export', _at).saveToDownloads();
        // Own errors immediately, including a failure before the native boundary.
        final outcome = first.then<Object>((value) => value, onError: (Object error) => error);
        addTearDown(() async {
          if (!held.release.isCompleted) held.release.complete();
          await outcome;
        });
        await Future.any<Object>([held.entered.future, outcome]);
        expect(held.entered.isCompleted, isTrue, reason: 'the first save must reach native IO');
        try {
          await make('second export', _at.add(Duration(seconds: seconds))).build();
        } finally {
          held.release.complete();
        }
        expect(await outcome, 'Download/DSH-Go/dsh-go-diagnostics-20261024-153012.zip');
        expect(_unzip(held.bytes!)['engine.log']!.trim(), 'first export');
      });
    }

    test('save removes only its operation directory after native completion', () async {
      final built = await exporter.build();
      final where = await exporter.saveToDownloads(onStep: steps.add);
      expect(where, 'Download/DSH-Go/dsh-go-diagnostics-20261024-153012.zip');
      final source = File(files.saved.single.path);
      expect(source.existsSync(), isFalse);
      expect(source.parent.existsSync(), isFalse);
      expect(built.existsSync(), isTrue, reason: 'a separate build still owns its root ZIP');
      expect(steps, [DiagnosticsStep.collecting, DiagnosticsStep.packing, DiagnosticsStep.saving]);
    });

    test('save cleans its operation on native failure and preserves the error', () async {
      final failure = PlatformException(code: 'permission', message: 'denied');
      final native = _FailingFiles(failure);
      final failed = DiagnosticsExporter(
        collect: (_) async => _snapshot(),
        files: native,
        cacheRoot: () async => cache,
        clock: () => _at,
      );
      await expectLater(failed.saveToDownloads(), throwsA(same(failure)));
      expect(native.source, isNotNull);
      expect(native.source!.parent.existsSync(), isFalse);
    });

    test('save cleans an allocated operation when collection fails', () async {
      final failure = StateError('collection failed');
      final failed = DiagnosticsExporter(
        collect: (_) async => throw failure,
        files: files,
        cacheRoot: () async => cache,
      );
      await expectLater(failed.saveToDownloads(), throwsA(same(failure)));
      expect(files.saved, isEmpty);
      expect(Directory('${cache.path}/diagnostics').listSync(), isEmpty);
    });

    test('share sends the ZIP to the share sheet', () async {
      expect(await exporter.share(onStep: steps.add), isTrue);
      final params = shared.single;
      expect(params.files!.single.name, 'dsh-go-diagnostics-20261024-153012.zip');
      expect(params.files!.single.mimeType, 'application/zip');
      expect(params.fileNameOverrides, ['dsh-go-diagnostics-20261024-153012.zip']);
      expect(steps.last, DiagnosticsStep.sharing);
    });

    test('errors in words', () {
      expect(diagnosticsErrorText(PlatformException(code: 'permission')), '没有存储权限，存不进「下载」');
      expect(diagnosticsErrorText(const FileSystemException('no space')), '存储空间不足，没能生成诊断包');
      expect(diagnosticsErrorText(StateError('x')), '没能导出诊断包');
    });
  });
}

class _Files extends FilesChannel {
  final saved = <({String path, String name, String mime})>[];

  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    expect(File(hostPath).existsSync(), isTrue);
    saved.add((path: hostPath, name: name, mime: mime));
    return 'Download/DSH-Go/$name';
  }
}

/// Models FilesPlugin opening its source on the worker after the channel call.
class _HeldFiles extends FilesChannel {
  final entered = Completer<String>();
  final release = Completer<void>();
  List<int>? bytes;

  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    entered.complete(hostPath);
    await release.future;
    bytes = await File(hostPath).readAsBytes();
    return 'Download/DSH-Go/$name';
  }
}

class _FailingFiles extends FilesChannel {
  _FailingFiles(this.failure);

  final Object failure;
  File? source;

  @override
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async {
    source = File(hostPath);
    expect(source!.existsSync(), isTrue);
    throw failure;
  }
}
