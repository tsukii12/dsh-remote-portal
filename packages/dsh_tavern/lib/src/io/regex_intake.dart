import '../regex/regex_engine.dart';
import '../regex/regex_types.dart';
import '../regex_library.dart';

/// Inspects execution views without mutating JSON or expanding any macro.
Future<List<TavernRegexDiagnostic>> inspectRegexScripts(
  Object? value,
  RegexExecutor worker, {
  String path = r'$.extensions.regex_scripts',
}) async {
  if (value == null) return const [];
  if (value is! List<Object?>) {
    return [
      TavernRegexDiagnostic(
        path: path,
        status: TavernRegexCompatibility.incompatible,
        code: 'invalid-rule-list',
        message: '正则列表必须为数组，原值保留但不执行。',
      ),
    ];
  }
  final result = <TavernRegexDiagnostic>[];
  for (var index = 0; index < value.length; index++) {
    final raw = value[index];
    final itemPath = '$path[$index]';
    if (raw is! Map<String, Object?>) {
      result.add(
        TavernRegexDiagnostic(
          path: itemPath,
          status: TavernRegexCompatibility.incompatible,
          code: 'invalid-rule',
          message: '正则条目必须为对象，原值保留但不执行。',
        ),
      );
      continue;
    }
    result.add(await inspectRegexScript(raw, worker, path: itemPath));
  }
  return List.unmodifiable(result);
}

Future<TavernRegexDiagnostic> inspectRegexScript(
  Map<String, Object?> raw,
  RegexExecutor worker, {
  String path = r'$',
}) async {
  final checked = await RegexEngine.checkScript(RegexScript.fromJson(raw), worker);
  return regexCompileDiagnostic(
    checked,
    path: checked.code == 'invalid-script' ? path : '$path.findRegex',
    identifier: raw['id'] is String ? raw['id'] as String : null,
  );
}

TavernRegexDiagnostic regexCompileDiagnostic(
  RegexCompileResult result, {
  required String path,
  String? identifier,
  int? line,
  String? decorator,
  int? keyIndex,
  bool conditional = false,
  bool fallback = false,
}) {
  final status = result.code == 'runtime-check'
      ? TavernRegexCompatibility.deferred
      : switch (result.status) {
          RegexCompileStatus.compatible =>
            result.code == 'literal-fallback'
                ? TavernRegexCompatibility.literalFallback
                : TavernRegexCompatibility.compatible,
          RegexCompileStatus.literalFallback => TavernRegexCompatibility.literalFallback,
          RegexCompileStatus.incompatible => TavernRegexCompatibility.incompatible,
          RegexCompileStatus.skipped => TavernRegexCompatibility.skipped,
        };
  return TavernRegexDiagnostic(
    path: path,
    identifier: identifier,
    status: status,
    line: line,
    decorator: decorator,
    keyIndex: keyIndex,
    conditional: conditional,
    fallback: fallback,
    code: result.code ?? 'compiled',
    message: result.message ?? '已按本来源的解析规则试编译。',
  );
}
