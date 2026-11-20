// Import graph of `app/lib`: which non-ui files import `ui/`, and how big the
// largest import cycle is.
//
//   cd app && dart run tool/import_graph.dart          # summary
//   cd app && dart run tool/import_graph.dart --edges  # also list every non-ui → ui edge
//
// `test/arch/import_direction_test.dart` uses the same scanner as its guard.
import 'dart:io';

const _package = 'dsh_app';

/// Files directly under `lib/` that wire the app together; they may import anything.
const compositionRoots = {'app.dart', 'main.dart'};

final _directive = RegExp(r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]([^;]*);''', multiLine: true);
final _conditional = RegExp(r'''\bif\s*\([^)]*\)\s*['"]([^'"]+)['"]''');

/// The library graph of `lib/`: each file (path relative to `lib/`, `/`-separated)
/// mapped to the `lib/` files it imports, exports or includes as a part.
Map<String, Set<String>> scanLib(Directory lib) {
  final root = lib.absolute.uri;
  final files = <String>[
    for (final entity in lib.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) _relative(root, entity.absolute.uri),
  ]..sort();
  final graph = <String, Set<String>>{};
  for (final file in files) {
    final source = File.fromUri(root.resolve(file)).readAsStringSync();
    final targets = <String>{};
    for (final match in _directive.allMatches(source)) {
      final uris = [match.group(2)!, ..._conditional.allMatches(match.group(3)!).map((m) => m.group(1)!)];
      for (final uri in uris) {
        final target = _resolve(file, uri);
        if (target != null) targets.add(target);
      }
    }
    graph[file] = targets;
  }
  return graph;
}

String _relative(Uri root, Uri file) => file.path.substring(root.path.length);

String? _resolve(String from, String uri) {
  if (uri.startsWith('package:')) {
    const prefix = 'package:$_package/';
    return uri.startsWith(prefix) ? uri.substring(prefix.length) : null;
  }
  if (uri.contains(':')) return null; // dart:, other schemes
  final resolved = Uri.parse('file:///$from').resolve(uri).path.substring(1);
  return resolved;
}

bool isUi(String file) => file.startsWith('ui/');

/// Top-level directory of [file] (`state`, `plugins`, …), or the file name for files directly under `lib/`.
String topLevel(String file) => file.split('/').first;

/// Every edge from a non-ui file (outside [compositionRoots]) into `ui/`, as `from -> to`.
List<String> nonUiToUiEdges(Map<String, Set<String>> graph) => [
  for (final MapEntry(key: from, value: targets) in graph.entries)
    if (!isUi(from) && !compositionRoots.contains(from))
      for (final to in targets.where(isUi).toList()..sort()) '$from -> $to',
];

/// Strongly connected components with more than one file, largest first (Tarjan, iterative).
List<List<String>> cycles(Map<String, Set<String>> graph) {
  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final result = <List<String>>[];
  var next = 0;
  for (final start in graph.keys) {
    if (index.containsKey(start)) continue;
    final work = <(String, Iterator<String>)>[];
    void enter(String node) {
      index[node] = low[node] = next++;
      stack.add(node);
      onStack.add(node);
      work.add((node, (graph[node] ?? const <String>{}).where(graph.containsKey).iterator));
    }

    enter(start);
    while (work.isNotEmpty) {
      final (node, edges) = work.last;
      if (edges.moveNext()) {
        final target = edges.current;
        if (!index.containsKey(target)) {
          enter(target);
        } else if (onStack.contains(target)) {
          low[node] = low[node]! < index[target]! ? low[node]! : index[target]!;
        }
        continue;
      }
      work.removeLast();
      if (work.isNotEmpty) {
        final parent = work.last.$1;
        low[parent] = low[parent]! < low[node]! ? low[parent]! : low[node]!;
      }
      if (low[node] == index[node]) {
        final component = <String>[];
        String member;
        do {
          member = stack.removeLast();
          onStack.remove(member);
          component.add(member);
        } while (member != node);
        if (component.length > 1) result.add(component..sort());
      }
    }
  }
  result.sort((a, b) => b.length.compareTo(a.length));
  return result;
}

void main(List<String> args) {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    stderr.writeln('Run from app/: cd app && dart run tool/import_graph.dart');
    exitCode = 2;
    return;
  }
  final graph = scanLib(lib);
  final edges = nonUiToUiEdges(graph);
  final byDir = <String, int>{};
  for (final edge in edges) {
    final dir = topLevel(edge.split(' -> ').first);
    byDir[dir] = (byDir[dir] ?? 0) + 1;
  }
  final components = cycles(graph);
  final inCycles = components.fold<int>(0, (sum, c) => sum + c.length);
  stdout.writeln('files in lib/: ${graph.length}');
  stdout.writeln('files in import cycles: $inCycles (${components.length} cycles)');
  stdout.writeln('largest cycle: ${components.isEmpty ? 0 : components.first.length} files');
  final cycleDirs = <String, int>{};
  if (components.isNotEmpty) {
    for (final file in components.first) {
      cycleDirs[topLevel(file)] = (cycleDirs[topLevel(file)] ?? 0) + 1;
    }
  }
  stdout.writeln(
    '  by directory: ${(cycleDirs.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => '${e.key} ${e.value}').join(', ')}',
  );
  stdout.writeln('non-ui -> ui edges: ${edges.length}');
  for (final entry in byDir.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
  if (args.contains('--edges')) {
    for (final edge in edges) {
      stdout.writeln(edge);
    }
  }
}
