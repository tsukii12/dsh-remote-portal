part of 'slash_language.dart';

class SlashSource {
  SlashSource(this.text, {this.id, this.assetId, this.version, this.callSite});
  final String text;
  final String? id, assetId, version;
  final TavernScriptSourceSpan? callSite;
  List<int> _lines = <int>[0];
  Future<void> prepareLineIndex(void Function() checkCancelled) async {
    checkCancelled();
    final lines = <int>[0];
    var position = 0, work = 0;
    while (position < text.length) {
      final before = position;
      final code = text.codeUnitAt(position++);
      if (code == 13) {
        if (position < text.length && text.codeUnitAt(position) == 10) position++;
        lines.add(position);
      } else if (code == 10) {
        lines.add(position);
      }
      work += position - before;
      if (work >= 4096) {
        work = 0;
        checkCancelled();
        await Future<void>.delayed(Duration.zero);
        checkCancelled();
      }
    }
    checkCancelled();
    _lines = lines;
  }

  TavernScriptSourceSpan span(int start, int end) {
    var low = 0, high = _lines.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (_lines[middle] <= start) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return TavernScriptSourceSpan(sourceId: id, start: start, end: end, line: low + 1, column: start - _lines[low] + 1);
  }
}

class SlashAssignment {
  const SlashAssignment({this.name, required this.value, required this.span, this.quoted = false});
  final String? name;

  /// String, SlashProgram, or ScriptCoercion.undefined for a missing initializer.
  final Object? value;
  final TavernScriptSourceSpan span;
  final bool quoted;
}

class SlashProgram {
  SlashProgram({
    required this.source,
    required this.span,
    required List<SlashAssignment> defaults,
    required List<SlashNode> commands,
    this.executeNow = false,
  }) : defaults = List.unmodifiable(defaults),
       commands = List.unmodifiable(commands);
  final SlashSource source;
  final TavernScriptSourceSpan span;
  final List<SlashAssignment> defaults;
  final List<SlashNode> commands;
  final bool executeNow;
}

class SlashNode {
  SlashNode({
    required this.name,
    required this.span,
    required List<SlashAssignment> named,
    required List<SlashAssignment> unnamed,
    this.injectPipe = true,
    this.shorthand = false,
  }) : named = List.unmodifiable(named),
       unnamed = List.unmodifiable(unnamed);
  final String name;
  final TavernScriptSourceSpan span;
  final List<SlashAssignment> named, unnamed;
  final bool injectPipe, shorthand;
  SlashDescriptor? get descriptor => slashDescriptors[name];
}

class SlashClosure {
  const SlashClosure(this.program, {this.parent});
  final SlashProgram program;
  final SlashFrame? parent;
  bool get executeNow => program.executeNow;
  @override
  String toString() => executeNow ? '[Closure]()' : '[Closure]';
}

class SlashInvocation {
  SlashInvocation({
    required this.node,
    required this.frame,
    required Map<String, Object?> named,
    required this.unnamed,
    required List<Object?> unnamedParts,
    required this.incomingPipe,
    required this.commandIndex,
    required this.implicitPipe,
  }) : named = Map.unmodifiable(named),
       unnamedParts = List.unmodifiable(unnamedParts);
  final SlashNode node;
  final SlashFrame frame;
  final Map<String, Object?> named;
  final Object? unnamed, incomingPipe;
  final List<Object?> unnamedParts;
  final int commandIndex;
  final bool implicitPipe;
  String get command => node.descriptor?.canonical ?? node.name;
  String get spelling => node.name;
  TavernScriptSourceSpan get sourceSpan => node.span;
  bool get hasParsedUnnamed => node.unnamed.isNotEmpty;
  bool get hasUnnamed => hasParsedUnnamed || implicitPipe;
  bool has(String name) => named.containsKey(name);
  Object? argument(String name) => named.containsKey(name) ? named[name] : ScriptCoercion.undefined;
}

TavernScriptException _languageError(
  TavernScriptErrorCode code,
  String operation,
  String message,
  TavernScriptSourceSpan? span,
) => TavernScriptException(code: code, operation: operation, message: message, sourceSpan: span);

String slashPublicPipe(Object? value) {
  if (value is SlashClosure) return value.executeNow ? '[Closure]()' : '[Closure]';
  bool containsCallable(Object? item) =>
      item is SlashClosure ||
      item is List<Object?> && item.any(containsCallable) ||
      item is Map<String, Object?> && item.values.any(containsCallable);
  if (containsCallable(value)) {
    throw _languageError(
      TavernScriptErrorCode.shapeMismatch,
      'pipe',
      'A composite pipe cannot contain a callable closure.',
      null,
    );
  }
  if (value == null || ScriptCoercion.isUndefined(value)) return '';
  if (value is String) return value;
  return ScriptCoercion.json(value) ?? '';
}

Object? _callbackPipe(Object? value) {
  if (value is SlashClosure || value is String) return value;
  return slashPublicPipe(value);
}
