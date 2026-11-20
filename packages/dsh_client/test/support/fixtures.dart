import 'dart:convert';
import 'dart:io';

/// Captured, redacted frames from DSH 0.2.0-rc.2 (see test/fixtures/README.md).
List<Object?> loadJsonl(String name) =>
    File('test/fixtures/$name').readAsLinesSync().where((line) => line.trim().isNotEmpty).map(jsonDecode).toList();

Object? loadJson(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync());
