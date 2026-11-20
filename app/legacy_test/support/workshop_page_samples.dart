/// Test-only, immutable page snapshots produced by the real state controllers.
///
/// These factories use the repository's existing in-memory test seams. They do
/// not open HTTP, archives, platform channels, or private files, and instantiate
/// no widgets. Await a factory, then render its public state in a preview or a
/// golden test. Its container has already been disposed: disclosure/replacement/
/// report tokens describe that snapshot and are NOT authorization for a new live
/// controller. Interactive previews must drive their own live notifier instead.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_install_state.dart';
import 'package:dsh_app/state/workshop_installed_state.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/state/workshop_report_state.dart';
import 'package:dsh_app/state/workshop_submissions_state.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/workshop_auth_test_support.dart';
import '../state/workshop_personal_test_support.dart';
import '../state/workshop_publish_test_support.dart';
import '../state/workshop_state_support.dart';
import '../workshop/support.dart' show workshopCaps;

part 'workshop_preview_samples.dart';
part 'workshop_browse_samples.dart';
part 'workshop_install_samples.dart';
part 'workshop_installed_samples.dart';
part 'workshop_access_samples.dart';
part 'workshop_publish_samples.dart';
part 'workshop_personal_samples.dart';
part 'workshop_recovery_samples.dart';

/// All names and attribution are synthetic layout data, not real publications.
/// Long names are still legal metadata (at most 120 Unicode code points).
/// Invalid over-limit text is provided separately by the form-error factories.
enum WorkshopSampleText { shortChinese, longChinese, emoji, english }

WorkshopPublicationInput workshopSampleInput({
  WorkshopSampleText text = WorkshopSampleText.shortChinese,
  bool rights = false,
}) {
  final (title, english, author, description, tags) = switch (text) {
    WorkshopSampleText.shortChinese => (
      '月白', 'Moon Cat', '阿禾', '安静地陪你完成今天的小事。', ['像素', '陪伴']),
    WorkshopSampleText.longChinese => (
      '住在旧书店窗边的守夜猫——陪你读完最后一页、写下今天的心事，在雨天守着一盏暖灯，在晴夜数屋檐上的星星；'
      '送给喜欢纸张气味、安静音乐与漫长散步的你，也送给每一个正在认真完成小小心愿、把日常过得温柔而坚定的人',
      'The Little Night Watcher at the Bookshop Window',
      '山间邮局与旧书店的手绘创作小组',
      '这只守夜猫来自我们常去的一家旧书店。它总把尾巴搭在窗台边，听雨滴落在门口的遮雨棚上，也会在店主整理书架时轻轻抬头。'
      '我们把这些安静的小动作画进了这个角色，希望它能陪你阅读、写作，或者只是留一点不被催促的时间。'
      '画面采用柔和的暖灰与浅金色，适合搭配明亮或深色背景；每一帧都保留了铅笔线条的小小起伏，让角色看起来像从手账里走出来一样。'
      '这个版本补充了眨眼和抖耳朵的细节，并调整了尾巴摆动的节奏。名称、图像和动画均由创作小组共同整理，'
      '欢迎在注明作者后分享自己的桌面搭配，也欢迎告诉我们你最喜欢哪一个瞬间。'
      '如果它让你想起某个熟悉的夜晚、一本读到一半的书，或者一位总会耐心听你说话的朋友，那就是我们最期待的相遇。'
      '愿你每天都能为喜欢的事情留下一点空间。',
      ['手绘角色', '阅读', '夜晚']),
    WorkshopSampleText.emoji => (
      '云端旅人 ☁️✨', 'Cloud Traveller ☁️✨', '阿澄 🎨',
      '带着小灯出发，遇见星星就停下来看看 🌙', ['旅途', '星空 ✨']),
    WorkshopSampleText.english => (
      'Evening Fox', 'Evening Fox', 'Maple Studio',
      'A quiet companion for reading, coding, and late evening sketches.',
      ['evening', 'hand-drawn']),
  };
  return WorkshopPublicationInput(id: 'moon-cat', version: '2.0.0', minApp: '1.0.0',
    titleZh: title, titleEn: english, author: author, license: 'CC-BY-4.0',
    source: 'https://samples.example/characters/moon-cat', description: description,
    tags: tags, rightsConfirmed: rights);
}

WorkshopEntry workshopSampleEntry({String kind = 'pet', String id = 'moon-cat',
  String version = '2.0.0', String minApp = '1.0.0',
  WorkshopSampleText text = WorkshopSampleText.shortChinese,
  List<String> blocked = const [], String? hash}) {
  final input = workshopSampleInput(text: text).copyWith(id: id, version: version, minApp: minApp);
  final metadata = {...input.declaration(kind), 'sha256': hash ?? 'a' * 64, 'size': 4};
  return WorkshopEntry.fromJson({...metadata,
    'url': '/market/workshop/$kind/$id/$version/${metadata['sha256']}.zip',
    'blockedVersions': blocked});
}

WorkshopInstalled workshopSampleInstalled({String kind = 'pet', String id = 'moon-cat',
  String version = '2.0.0', Uri? origin, String? issue, String? hash}) => WorkshopInstalled(
    localId: kind == 'companion' ? 'companion' : 'user-$id', issue: issue,
    receipt: WorkshopReceipt(kind: kind, id: id, version: version,
      sha256: hash ?? 'a' * 64, origin: origin ?? stateOrigin));

WorkshopCatalogSnapshot _sampleCatalog({List<WorkshopEntry>? entries,
  bool stale = false, bool companion = true,
  List<WorkshopInstalled> withdrawn = const [], WorkshopException? refreshError,
  String? cacheIssue}) => WorkshopCatalogSnapshot(
    catalog: WorkshopCatalog.fromJson({
      'schema': 1, 'generatedAt': '2026-11-12T00:00:00.000Z',
      'features': {'uploads': true, 'companion': companion},
      'entries': (entries ?? [workshopSampleEntry()]).map((item) => item.toJson()).toList(),
      'withdrawn': [for (final item in withdrawn) {
        'kind': item.receipt.kind, 'id': item.receipt.id, 'version': item.receipt.version,
        'reason': '作者撤回这个版本，准备补充授权说明。', 'at': '2026-11-12T00:00:00.000Z',
      }],
    }), fetchedAt: DateTime.utc(2026, 11, 12), stale: stale,
    refreshError: refreshError, cacheIssue: cacheIssue);

/// A controlled gate. No wall-clock delay or fake timer decides when a
/// sample is captured. Every caller releases and drains its started operation.
class _SampleGate {
  final entered = Completer<void>();
  final _release = Completer<void>();
  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return _release.future;
  }
  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

Future<T> _sampleWhile<T, R>(Future<R> pending, _SampleGate gate, T Function() read) async {
  final settled = stateSettled(pending);
  try {
    await Future.any<void>([
      gate.entered.future,
      pending.then<void>((_) {
        if (!gate.entered.isCompleted) {
          throw StateError('Sample operation completed before its capture gate');
        }
      }),
    ]);
    return read();
  } finally {
    gate.release();
    await settled;
  }
}

class _LocalSample {
  _LocalSample({StatePackages? packages, StateClient? client, String appVersion = '2.0.0',
    bool configured = true, WorkshopPackageChanged? changed})
    : packages = packages ?? StatePackages(), client = client ?? StateClient() {
    repository = StateRepository(this.client, this.packages, appVersion: appVersion);
    container = stateContainer(packages: this.packages,
      sources: [StateSource(this.client, repository)], configured: configured, changed: changed);
  }
  final StatePackages packages;
  final StateClient client;
  late final StateRepository repository;
  late final ProviderContainer container;
  Future<void> catalogReady() => container.read(workshopCatalogProvider.notifier).ready;
  Future<void> installedReady() async {
    await container.read(workshopInstalledProvider.notifier).ready;
    await catalogReady();
    await container.read(workshopInstalledProvider.notifier).refresh();
  }
  void dispose() => container.dispose();
}
