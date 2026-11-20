/// 状态 drawn the way the card asks (docs/design/roleplay-agent.md §2.2,
/// roleplay-ui.md §8): `x-dsh-show` on a field's schema says bar, number,
/// tags, inventory, list or line. Read from the schema the engine hands back
/// as written; any other word, a value it does not fit, or no schema at all (a
/// card without state) draws plainly.
library;

import 'dart:convert';

/// The ways the panel knows to draw a field.
enum TavernStateShow { bar, number, tags, inventory, list, line }

/// The schema for [path] (a JSON Pointer) under [schema]: an object's
/// `properties` by name, or its `additionalProperties` schema; an array's
/// `items` by index. Null where the schema says nothing about it.
Map<String, Object?>? tavernStateSchemaAt(Object? schema, String path) {
  if (schema is! Map<String, Object?>) return null;
  var node = schema;
  if (path.isEmpty) return node;
  for (final raw in path.substring(1).split('/')) {
    final key = raw.replaceAll('~1', '/').replaceAll('~0', '~');
    final next = switch (node) {
      {'properties': final Map<String, Object?> properties} when properties.containsKey(key) => properties[key],
      {'items': final Map<String, Object?> items} when int.tryParse(key) != null => items,
      {'additionalProperties': final Map<String, Object?> extra} => extra,
      _ => null,
    };
    if (next is! Map<String, Object?>) return null;
    node = next;
  }
  return node;
}

/// How the card asks [value] at [path] to be drawn, when it is a way we know
/// and the value fits it: a bar needs a number and a range, tags a list, a bag
/// or a list a list or an object.
TavernStateShow? tavernStateShow(Object? schema, String path, Object? value) {
  final node = tavernStateSchemaAt(schema, path);
  if (node == null) return null;
  final show = TavernStateShow.values.asNameMap()[node['x-dsh-show']];
  return switch (show) {
    TavernStateShow.bar when value is num && tavernStateRange(node) != null => show,
    TavernStateShow.number when value is num => show,
    TavernStateShow.tags when value is List<Object?> => show,
    TavernStateShow.inventory ||
    TavernStateShow.list when value is List<Object?> || value is Map<String, Object?> => show,
    TavernStateShow.line => show,
    _ => null,
  };
}

/// The bar's ends: the schema's `minimum` (0 if it gives none) and `maximum`.
(num, num)? tavernStateRange(Map<String, Object?> node) {
  final low = switch (node['minimum']) {
    final num n => n,
    _ => 0,
  };
  return switch (node['maximum']) {
    final num high when high > low => (low, high),
    _ => null,
  };
}

/// How far along [range] [value] sits, 0 to 1.
double tavernStateFraction(num value, (num, num) range) =>
    ((value - range.$1) / (range.$2 - range.$1)).clamp(0, 1).toDouble();

/// [value] on a line: text as written, a list of words as a list (a bag,
/// say), the rest as compact JSON.
String tavernStateText(Object? value) => switch (value) {
  final String text => text,
  null => 'null',
  final List<Object?> list when list.isNotEmpty && list.every((item) => item is String) => list.join('、'),
  _ => jsonEncode(value),
};

/// A field drawn on one line: an object's values, or a list's items, side by
/// side (time and place, say); anything else as [tavernStateText].
String tavernStateLine(Object? value) => switch (value) {
  final Map<String, Object?> map => [
    for (final item in map.values)
      if (item != null) tavernStateText(item),
  ].join(' · '),
  final List<Object?> list => [for (final item in list) tavernStateText(item)].join(' · '),
  _ => tavernStateText(value),
};

/// A field drawn as a list: a list's items, or an object's entries as
/// 「name：value」.
List<String> tavernStateEntries(Object? value) => switch (value) {
  final List<Object?> list => [for (final item in list) _entry(item)],
  final Map<String, Object?> map => [for (final MapEntry(:key, :value) in map.entries) '$key：${_entry(value)}'],
  _ => const [],
};

String _entry(Object? item) => item is Map<String, Object?> ? tavernStateLine(item) : tavernStateText(item);

/// One thing in a bag: what it is and, when the card keeps one, how many.
typedef TavernStateGood = ({String name, num? count});

/// A bag's things: a list of names or of objects (name and count under the
/// usual keys), or an object from name to count.
List<TavernStateGood> tavernStateGoods(Object? value) => switch (value) {
  final List<Object?> list => [for (final item in list) _good(item)],
  final Map<String, Object?> map => [
    for (final MapEntry(:key, value: item) in map.entries)
      switch (item) {
        final num count => (name: key, count: count),
        final Map<String, Object?> about => (name: key, count: _count(about)),
        null || true => (name: key, count: null),
        _ => (name: '$key：${tavernStateText(item)}', count: null),
      },
  ],
  _ => const [],
};

const _names = ['name', 'item', 'title', 'label', '名称', '名字', '物品'];
const _counts = ['count', 'qty', 'quantity', 'amount', 'num', '数量'];

TavernStateGood _good(Object? item) {
  if (item is! Map<String, Object?>) return (name: tavernStateText(item), count: null);
  final name = [
    for (final key in _names)
      if (item[key] case final String name when name.isNotEmpty) name,
  ].firstOrNull;
  return (name: name ?? tavernStateLine(item), count: name == null ? null : _count(item));
}

num? _count(Map<String, Object?> item) => [
  for (final key in _counts)
    if (item[key] case final num count) count,
].firstOrNull;
