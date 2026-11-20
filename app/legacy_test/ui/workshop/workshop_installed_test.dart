// The 已安装 tab (ui/workshop/workshop_installed.dart) and its row sheet:
// what each state of workshopInstalledProvider looks like, that 卸载 asks
// first and passes the row's own object, what a refused or failed uninstall
// says, and that no code or exception text reaches the screen.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_install_state.dart';
import 'package:dsh_app/state/workshop_installed_state.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workshop/workshop_installed.dart';
import 'package:dsh_app/ui/workshop/workshop_screen.dart';
import 'package:dsh_app/ui/workshop/workshop_installed_sheet.dart';
import 'package:dsh_app/ui/workshop/workshop_item_sheet.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../state/workshop_state_support.dart';
import '../../support/test_fonts.dart';

class _Installed extends WorkshopInstalledController {
  _Installed(this._initial);

  final WorkshopInstalledListState _initial;
  final uninstalled = <WorkshopLocalEntry>[];
  int refreshes = 0;
  bool accepts = true;

  /// What the next read of the phone produces; null leaves the state alone.
  WorkshopInstalledListState? nextOnRefresh;

  /// Runs while the catalogue is being asked, before the phone is read.
  void Function()? duringCatalog;

  @override
  WorkshopInstalledListState build() => _initial;

  @override
  Future<void> refresh() async {
    refreshes++;
    if (nextOnRefresh case final next?) state = next;
  }

  @override
  Future<bool> uninstall(WorkshopLocalEntry entry) async {
    uninstalled.add(entry);
    return accepts;
  }

  void show(WorkshopInstalledListState next) => state = next;
}

class _Catalog extends WorkshopCatalogController {
  _Catalog(this._items);

  final List<WorkshopItemState> _items;
  int refreshes = 0;

  @override
  WorkshopCatalogState build() => WorkshopCatalogState(items: _items, localStateKnown: true);

  @override
  Future<void> refresh() async {
    refreshes++;
    installed?.duringCatalog?.call();
  }

  /// The installed controller of the same bench, for what happens mid-pull.
  _Installed? installed;
}

class _Install extends WorkshopInstallController {
  @override
  WorkshopInstallState build() => const WorkshopInstallState();
}

class _Bench {
  _Bench(this.installed, this.catalog);

  final _Installed installed;
  final _Catalog catalog;
  int browsed = 0;
}

Future<_Bench> _pump(
  WidgetTester tester,
  WorkshopInstalledListState state, {
  List<WorkshopItemState> catalog = const [],
  double width = 390,
  double scale = 1,
  Locale locale = const Locale('zh', 'CN'),
  bool wholePage = false,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  addTearDown(tester.view.reset);
  final bench = _Bench(_Installed(state), _Catalog(catalog));
  bench.catalog.installed = bench.installed;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workshopInstalledProvider.overrideWith(() => bench.installed),
        workshopCatalogProvider.overrideWith(() => bench.catalog),
        workshopInstallProvider.overrideWith(_Install.new),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withTestFonts(buildLightTheme()),
        locale: locale,
        supportedLocales: L10n.supportedLocales,
        localizationsDelegates: L10n.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: wholePage
            ? const WorkshopScreen(initialTab: WorkshopTab.installed)
            : Scaffold(
                body: CustomScrollView(
                  slivers: [WorkshopInstalledSliver(onBrowse: () => bench.browsed++)],
                ),
              ),
      ),
    ),
  );
  await tester.pump();
  return bench;
}

WorkshopInstalledListState _list(
  List<WorkshopInstalledRow> rows, {
  String? loadError,
  String? catalogError,
  bool? catalogStale,
  WorkshopRemovalState removal = const WorkshopRemovalState(),
}) => WorkshopInstalledListState(
  rows: rows,
  loadError: loadError,
  catalogError: catalogError,
  catalogStale: catalogStale,
  removal: removal,
);

/// A row the catalogue has not spoken about.
WorkshopInstalledRow _local(WorkshopLocalEntry local) => WorkshopInstalledRow(local: local);

/// A row with the catalogue's half.
WorkshopInstalledRow _known(
  WorkshopInstalled local, {
  WorkshopEntry? entry,
  String? unavailable,
  bool update = false,
  bool withdrawn = false,
}) => WorkshopInstalledRow(
  local: local,
  remote: WorkshopInstalledState(
    installed: local,
    entry: entry,
    unavailable: unavailable,
    updateAvailable: update,
    installedWithdrawn: withdrawn,
  ),
);

const _untrusted = WorkshopInstallationIssue(localId: 'user:untrusted', issue: 'workshop_install_record');

Finder get _sheet => find.byType(WorkshopInstalledSheet);
Finder _inSheet(String text) => find.descendant(of: _sheet, matching: find.text(text));
Finder get _sheetUninstall => find.widgetWithText(OutlinedButton, '卸载');
Finder get _dialogUninstall => find.widgetWithText(FilledButton, '卸载');

/// Nothing a person should never read: codes, exception names.
void _expectNoRawText() {
  expect(find.textContaining('workshop_'), findsNothing);
  expect(find.textContaining('Exception'), findsNothing);
}

void main() {
  group('the list', () {
    testWidgets('before the first read: one quiet ring, no empty state', (tester) async {
      await _pump(tester, WorkshopInstalledListState(loading: true));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(EmptyView), findsNothing);
    });

    testWidgets('nothing installed: one line and the way to 发现', (tester) async {
      final bench = await _pump(tester, _list(const []));

      expect(find.text('还没有从工坊装过东西'), findsOneWidget);
      await tester.tap(find.text('去发现'));
      expect(bench.browsed, 1);
    });

    testWidgets('the local read failed with nothing older: says so, 重试 reads again', (tester) async {
      final bench = await _pump(tester, _list(const [], loadError: 'workshop_storage'));

      expect(find.text('读不出已安装的内容'), findsOneWidget);
      expect(find.text('没能读写手机上的文件。'), findsOneWidget);
      expect(find.text('去发现'), findsNothing);
      _expectNoRawText();

      await tester.tap(find.text('重试'));
      expect(bench.installed.refreshes, 1);
    });

    testWidgets('the local read failed with rows: they stay, a line offers 重试', (tester) async {
      final bench = await _pump(tester, _list([_local(stateInstalled())], loadError: 'workshop_some_new_code'));

      expect(find.text('cat'), findsOneWidget);
      expect(find.text('没能重新读取，显示的是上一次的。'), findsOneWidget);
      _expectNoRawText();

      await tester.tap(find.text('重试'));
      expect(bench.installed.refreshes, 1);
    });

    testWidgets('catalogue trouble is a quiet line that does not blame the network', (tester) async {
      final bench = await _pump(
        tester,
        _list([_known(stateInstalled(), entry: stateEntry(version: '1.0.0'))], catalogError: 'workshop_network'),
      );

      expect(find.text('小猫'), findsOneWidget);
      expect(find.text('更新和撤回的信息可能不是最新的。'), findsOneWidget);
      expect(find.textContaining('网络'), findsNothing);
      _expectNoRawText();

      // 重试 asks the catalogue again, then re-reads the rows.
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(bench.catalog.refreshes, 1);
      expect(bench.installed.refreshes, 1);
    });

    testWidgets('no catalogue half at all: says the info is missing, not stale', (tester) async {
      await _pump(tester, _list([_local(stateInstalled())], catalogError: 'workshop_unconfigured'));

      expect(find.text('暂时查不到更新和撤回的信息。'), findsOneWidget);
      // Nothing to retry against when no workshop is configured.
      expect(find.text('重试'), findsNothing);
      expect(find.text('cat'), findsOneWidget);
    });

    testWidgets('an old catalogue (stale, no error) gets the same quiet line', (tester) async {
      await _pump(tester, _list([_known(stateInstalled(), entry: stateEntry(version: '1.0.0'))], catalogStale: true));

      expect(find.text('更新和撤回的信息可能不是最新的。'), findsOneWidget);
    });

    testWidgets('each row says the one thing that matters about it', (tester) async {
      await _pump(
        tester,
        _list([
          _local(stateInstalled(id: 'plain')),
          _known(stateInstalled(id: 'fresh'), entry: stateEntry(id: 'fresh', zh: '新猫'), update: true),
          _known(stateInstalled(id: 'pulled'), unavailable: 'workshop_version_withdrawn', withdrawn: true),
          _known(stateInstalled(id: 'far', origin: otherStateOrigin), unavailable: 'workshop_other_origin'),
          _known(stateInstalled(id: 'lost'), unavailable: 'workshop_not_found'),
          _local(stateInstalled(id: 'broken', issue: 'workshop_pet_bad_pack')),
          _local(stateInstalled(kind: 'companion', id: 'she', version: '3.1.0')),
          _local(_untrusted),
        ]),
      );

      // No public entry: the receipt's id is the name; no catalogue half:
      // nothing about updates or withdrawal.
      expect(find.text('plain'), findsOneWidget);
      expect(find.text('像素宠物 · 1.0.0'), findsOneWidget);
      expect(find.text('新猫'), findsOneWidget);
      expect(find.text('1.0.0 · 有更新'), findsOneWidget);
      expect(find.text('1.0.0 · 这个版本已被撤回'), findsOneWidget);
      expect(find.text('1.0.0 · 来自别的工坊'), findsOneWidget);
      expect(find.text('1.0.0 · 工坊里现在找不到它'), findsOneWidget);
      expect(find.text('1.0.0 · 这个包损坏了'), findsOneWidget);
      expect(find.text('伙伴 · 3.1.0'), findsOneWidget);
      // No trusted receipt: the local id and the problem, nothing guessed.
      expect(find.text('user:untrusted'), findsOneWidget);
      expect(find.text('安装记录对不上'), findsOneWidget);
      _expectNoRawText();
    });

    testWidgets('a problem code nobody has named gets the general line', (tester) async {
      await _pump(tester, _list([_local(stateInstalled(issue: 'workshop_companion_disabled'))]));

      expect(find.text('1.0.0 · 这一项有问题'), findsOneWidget);
      _expectNoRawText();
    });

    testWidgets('360 wide at 1.3×: long names and lines do not overflow', (tester) async {
      final long = stateEntry(id: 'long', zh: '一只名字特别特别特别特别特别特别长的小猫咪和它的朋友们');
      await _pump(
        tester,
        _list(
          [
            _known(stateInstalled(id: 'long'), entry: long, unavailable: 'workshop_version_rewritten'),
            _known(stateInstalled(id: 'pulled'), unavailable: 'workshop_version_withdrawn', withdrawn: true),
            _local(
              const WorkshopInstallationIssue(
                localId: 'user:a-very-long-local-identifier-that-goes-on-and-on',
                issue: 'workshop_install_record',
              ),
            ),
          ],
          loadError: 'workshop_storage',
          catalogError: 'workshop_network',
        ),
        width: 360,
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.textContaining('一只名字'));
      await tester.pumpAndSettle();
      expect(_sheet, findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(_sheetUninstall);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('English: the same states read in English', (tester) async {
      await _pump(
        tester,
        _list([
          _known(stateInstalled(), entry: stateEntry(), update: true),
          _local(_untrusted),
        ], catalogError: 'workshop_timeout'),
        width: 360,
        scale: 1.3,
        locale: const Locale('en'),
      );

      expect(find.text('Cat'), findsOneWidget);
      expect(find.text('1.0.0 · Update available'), findsOneWidget);
      expect(find.text("Install record doesn't match"), findsOneWidget);
      expect(find.text('Update and withdrawal info may be out of date.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the sheet', () {
    testWidgets('a trusted row: kind, id, version, and where it came from as a host', (tester) async {
      await _pump(
        tester,
        _list([_known(stateInstalled(id: 'far', origin: otherStateOrigin), unavailable: 'workshop_other_origin')]),
      );

      await tester.tap(find.text('far'));
      await tester.pumpAndSettle();

      expect(_inSheet('像素宠物'), findsOneWidget);
      expect(_inSheet('far'), findsNWidgets(2)); // the title and the id
      expect(_inSheet('1.0.0'), findsOneWidget);
      expect(_inSheet('other-workshop.example'), findsOneWidget);
      expect(_inSheet('这是从别的工坊装的，这里查不到它的更新。'), findsOneWidget);
      // Removable wherever it came from; nothing to update from here.
      expect(_sheetUninstall, findsOneWidget);
      expect(find.textContaining('更新到'), findsNothing);
      _expectNoRawText();
    });

    testWidgets('a broken pack with a trusted receipt: says both, still removable', (tester) async {
      await _pump(
        tester,
        _list([
          _known(
            stateInstalled(issue: 'workshop_pet_bad_pack'),
            unavailable: 'workshop_version_withdrawn',
            withdrawn: true,
          ),
        ]),
      );

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();

      expect(_inSheet('这个包损坏了，可能用不了。'), findsOneWidget);
      expect(_inSheet('你装的这个版本已经被撤回。它还能用；有新版本就更新，没有的话建议卸载。'), findsOneWidget);
      expect(_sheetUninstall, findsOneWidget);
      _expectNoRawText();
    });

    testWidgets('no trusted receipt: the local id, the problem, why it cannot be removed, no 卸载', (tester) async {
      final bench = await _pump(tester, _list([_local(_untrusted)]));

      await tester.tap(find.text('user:untrusted'));
      await tester.pumpAndSettle();

      expect(_inSheet('本机标识'), findsOneWidget);
      expect(_inSheet('它的安装记录对不上。'), findsOneWidget);
      expect(_inSheet('安装记录不可信，没法从这里卸载它。'), findsOneWidget);
      expect(find.text('卸载'), findsNothing);
      // Nothing about a kind, a version or an origin it cannot vouch for.
      expect(_inSheet('类型'), findsNothing);
      expect(_inSheet('版本'), findsNothing);
      expect(_inSheet('来自'), findsNothing);
      expect(bench.installed.uninstalled, isEmpty);
      _expectNoRawText();
    });

    testWidgets('更新 opens the item\'s own sheet, where installing happens', (tester) async {
      final entry = stateEntry();
      final local = stateInstalled();
      await _pump(
        tester,
        _list([_known(local, entry: entry, update: true)]),
        catalog: [WorkshopItemState(entry: entry, installed: local, updateAvailable: true)],
      );

      await tester.tap(find.text('小猫'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: _sheet, matching: find.text('更新到 2.0.0')));
      await tester.pumpAndSettle();

      expect(_sheet, findsNothing);
      expect(find.byType(WorkshopItemSheet), findsOneWidget);
    });

    testWidgets('更新 when the catalogue no longer has the item: says to refresh, opens nothing', (tester) async {
      await _pump(tester, _list([_known(stateInstalled(), entry: stateEntry(), update: true)]));

      await tester.tap(find.text('小猫'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新到 2.0.0'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkshopItemSheet), findsNothing);
      expect(find.text('这个作品刚刚有变化，请刷新后再看。'), findsOneWidget);
    });

    testWidgets('the catalogue\'s half arriving while the sheet is up shows in it', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(tester, _list([_local(local)]));

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();
      expect(find.textContaining('更新到'), findsNothing);

      bench.installed.show(_list([_known(local, entry: stateEntry(), update: true)]));
      await tester.pumpAndSettle();
      expect(_inSheet('更新到 2.0.0'), findsOneWidget);
    });
  });

  group('uninstall', () {
    testWidgets('asks first; 取消 does nothing and leaves the sheet up', (tester) async {
      final bench = await _pump(tester, _list([_local(stateInstalled())]));

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetUninstall);
      await tester.pumpAndSettle();

      expect(find.text('卸载「cat」？'), findsOneWidget);
      expect(find.text('会删掉这台手机上的这一份。想再用，要回工坊重新获取。'), findsOneWidget);
      expect(bench.installed.uninstalled, isEmpty);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_sheet, findsOneWidget);
      expect(bench.installed.uninstalled, isEmpty);
    });

    testWidgets('confirmed: the row\'s own object goes to the controller, once, and the sheet closes', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(tester, _list([_local(local)]));

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetUninstall);
      await tester.pumpAndSettle();
      await tester.tap(_dialogUninstall);
      await tester.pumpAndSettle();

      expect(bench.installed.uninstalled, [same(local)]);
      expect(_sheet, findsNothing);
      // Accepted is not "done": nothing is announced until the state says so.
      expect(find.text('已卸载'), findsNothing);
    });

    testWidgets('an item the workshop no longer lists: the question says it may not come back', (tester) async {
      await _pump(tester, _list([_known(stateInstalled(), unavailable: 'workshop_not_found')]));

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetUninstall);
      await tester.pumpAndSettle();

      expect(find.textContaining('卸载后可能装不回来'), findsOneWidget);
    });

    testWidgets('refused (another operation is running): a brief notice, nothing claimed', (tester) async {
      final bench = await _pump(tester, _list([_local(stateInstalled())]));
      bench.installed.accepts = false;

      await tester.tap(find.text('cat'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetUninstall);
      await tester.pumpAndSettle();
      await tester.tap(_dialogUninstall);
      await tester.pump();
      await tester.pump();

      expect(bench.installed.uninstalled, hasLength(1));
      expect(find.text('上一个安装或卸载还没结束，等它完成再试。'), findsOneWidget);
      expect(find.text('已卸载'), findsNothing);
    });

    testWidgets('while it runs: the row shows progress and cannot be opened again', (tester) async {
      final local = stateInstalled();
      final other = stateInstalled(id: 'dog');
      final bench = await _pump(
        tester,
        _list(
          [_local(local), _local(other)],
          removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: local),
        ),
      );

      expect(find.text('正在卸载…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('cat'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_sheet, findsNothing);

      // Another row's sheet opens, but its 卸载 waits for the one running.
      await tester.tap(find.text('dog'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_sheet, findsOneWidget);
      expect(tester.widget<OutlinedButton>(_sheetUninstall).onPressed, isNull);
      expect(bench.installed.uninstalled, isEmpty);
    });

    testWidgets('succeeded: says 已卸载 once the state does', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(
        tester,
        _list([_local(local)], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: local)),
      );

      bench.installed.show(
        _list(const [], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.succeeded, target: local)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已卸载'), findsOneWidget);
      expect(find.text('还没有从工坊装过东西'), findsOneWidget);
    });

    testWidgets('succeeded but something else did not catch up: still a success, and says so', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(
        tester,
        _list([_local(local)], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: local)),
      );

      // The old row is still listed: the files are gone, the list is not re-read.
      bench.installed.show(
        _list(
          [_local(local)],
          removal: WorkshopRemovalState(
            phase: WorkshopRemovalPhase.succeeded,
            target: local,
            refreshError: 'workshop_local_refresh',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已卸载，但有些地方没能跟着更新，重新打开 App 就好。'), findsOneWidget);
      expect(find.textContaining('没能卸载'), findsNothing);
      // The stale row says it is gone and offers nothing more.
      expect(find.text('已卸载'), findsOneWidget);
      await tester.tap(find.text('cat'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_sheet, findsNothing);
      _expectNoRawText();
    });

    testWidgets('succeeded while the re-read failed on its own: also says the list is old', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(
        tester,
        _list([_local(local)], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: local)),
      );

      bench.installed.show(
        _list(
          [_local(local)],
          loadError: 'workshop_storage',
          removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.succeeded, target: local),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已卸载，但列表没能刷新，下拉刷新一下。'), findsOneWidget);
    });

    testWidgets('failed: the row keeps saying so and its sheet says why, in words', (tester) async {
      final local = stateInstalled(kind: 'companion', id: 'she');
      final bench = await _pump(
        tester,
        _list([_local(local)], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.removing, target: local)),
      );

      // A re-read hands out a new object for the same receipt.
      final again = stateInstalled(kind: 'companion', id: 'she');
      bench.installed.show(
        _list(
          [_local(again)],
          removal: WorkshopRemovalState(
            phase: WorkshopRemovalPhase.failed,
            target: local,
            error: 'workshop_readers_busy',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('没能卸载'), findsNWidgets(2)); // the row and the notice
      expect(find.text('已卸载'), findsNothing);
      _expectNoRawText();

      await tester.tap(find.text('she'));
      await tester.pumpAndSettle();
      expect(_inSheet('没能卸载。她正在用着，先离开伙伴小屋或关掉悬浮窗再试。'), findsOneWidget);
      // Trying again is the person's call, and goes through the question again.
      expect(_sheetUninstall, findsOneWidget);
      expect(bench.installed.uninstalled, isEmpty);
      _expectNoRawText();
    });

    testWidgets('a failed uninstall is put away by 「知道了」, and the row says what the phone says again', (tester) async {
      final local = stateInstalled(kind: 'companion', id: 'she');
      final bench = await _pump(
        tester,
        _list(
          [_local(local)],
          removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.failed, target: local, error: 'workshop_readers_busy'),
        ),
      );
      expect(find.text('没能卸载'), findsOneWidget);

      await tester.tap(find.text('she'));
      await tester.pumpAndSettle();
      await tester.tap(_inSheet('知道了'));
      await tester.pumpAndSettle();

      expect(bench.installed.state.removal.phase, WorkshopRemovalPhase.idle);
      expect(find.textContaining('没能卸载'), findsNothing);
      // Nothing was removed or read again by putting the result away.
      expect(bench.installed.uninstalled, isEmpty);
      expect(bench.installed.refreshes, 0);
      expect(_sheetUninstall, findsOneWidget);
    });

    Future<void> pull(WidgetTester tester) async {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
      await tester.pumpAndSettle();
    }

    testWidgets('a pull that reads the phone again puts the last result away; one that fails keeps it', (tester) async {
      final local = stateInstalled();
      final done = WorkshopRemovalState(phase: WorkshopRemovalPhase.succeeded, target: local);
      final bench = await _pump(tester, _list([_local(local)], removal: done), wholePage: true);
      expect(find.text('已卸载'), findsOneWidget);

      // The phone could not be read: the result still has something to say.
      bench.installed.nextOnRefresh = _list([_local(local)], loadError: 'workshop_storage', removal: done);
      await pull(tester);
      expect(bench.installed.refreshes, 1);
      expect(bench.installed.state.removal.phase, WorkshopRemovalPhase.succeeded);

      // Read again: the rows are current, the result has nothing to add.
      bench.installed.nextOnRefresh = _list(const [], removal: done);
      await pull(tester);
      expect(bench.installed.refreshes, 2);
      expect(bench.catalog.refreshes, 2);
      expect(bench.installed.state.removal.phase, WorkshopRemovalPhase.idle);
    });

    testWidgets('a result that arrives during a pull is news, and stays', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(tester, _list([_local(local)]), wholePage: true);
      final failed = WorkshopRemovalState(
        phase: WorkshopRemovalPhase.failed,
        target: local,
        error: 'workshop_readers_busy',
      );
      // An uninstall fails while the catalogue is being asked; the read after it works.
      bench.installed.duringCatalog = () => bench.installed.show(_list([_local(local)], removal: failed));
      bench.installed.nextOnRefresh = null;
      await pull(tester);

      expect(bench.installed.refreshes, 1);
      expect(identical(bench.installed.state.removal, failed), isTrue);
      expect(find.text('没能卸载'), findsOneWidget);
    });

    testWidgets('a result that is not this page\'s to announce stays quiet', (tester) async {
      final local = stateInstalled();
      final bench = await _pump(tester, _list([_local(local)]));

      // No removal was running here: a finished one is not news.
      bench.installed.show(
        _list(const [], removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.succeeded, target: local)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('已卸载'), findsNothing);
    });

    testWidgets('a later install into the same slot is not marked by the old result', (tester) async {
      final removed = stateInstalled();
      await _pump(
        tester,
        _list(
          [_local(stateInstalled())],
          removal: WorkshopRemovalState(phase: WorkshopRemovalPhase.succeeded, target: removed),
        ),
      );

      expect(find.text('已卸载'), findsNothing);
      expect(find.text('像素宠物 · 1.0.0'), findsOneWidget);
    });
  });
}
