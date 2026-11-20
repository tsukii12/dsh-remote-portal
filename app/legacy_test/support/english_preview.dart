// English preview runs of the existing golden tests (i18n checks):
//
//   DSH_TEST_LANG=en DSH_TEST_GOLDEN_OUT=/abs/dir flutter test test/settings
//
// switches appL10n to English and sends every golden to DSH_TEST_GOLDEN_OUT
// (<test dir>/<golden name>) instead of comparing it: the committed Chinese
// goldens are never read or written. Without the variables nothing changes.

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// True when this run renders English previews.
bool get englishPreview => Platform.environment['DSH_TEST_LANG'] == 'en';

void setUpEnglishPreview() {
  if (!englishPreview) return;
  AppLanguageController.initial = AppLanguage.en;
  AppLocale.use(AppLocale.en);
  final out = Platform.environment['DSH_TEST_GOLDEN_OUT'];
  final current = goldenFileComparator;
  if (out != null && current is LocalFileComparator) {
    goldenFileComparator = _PreviewComparator(Directory(out), current.basedir);
  }
}

class _PreviewComparator extends GoldenFileComparator {
  _PreviewComparator(this.out, this.testDir);

  final Directory out;
  final Uri testDir;

  File _target(Uri golden) {
    final dir = testDir.pathSegments.where((s) => s.isNotEmpty).last;
    return File('${out.path}/$dir/${golden.path}');
  }

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final f = _target(golden);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(imageBytes);
    return true;
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) => compare(imageBytes, golden);
}

/// English UI for one test: appL10n in English until the test ends.
void useEnglish() {
  AppLocale.use(AppLocale.en);
  addTearDown(() => AppLocale.use(englishPreview ? AppLocale.en : AppLocale.zhCN));
}

/// [child] laid out as English text (the paragraph locale picks Latin
/// punctuation widths); harnesses keep zh_CN for the rest of the app.
Widget inEnglish(Widget child) => Builder(
  builder: (context) => Localizations.override(context: context, locale: AppLocale.en, child: child),
);
