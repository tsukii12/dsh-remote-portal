// Automatic recall (C902), as this phone remembers it: which binding it made
// on each host and for which of her conversations, and the one consumer id
// this installation binds as. The host decides whether a binding is ready;
// this is only what to ask it about.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bindingsKey = 'companion_recall_bindings';
const _consumerKey = 'companion_recall_consumer';
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

class CompanionRecallRecord {
  const CompanionRecallRecord(this.bindingId, this.sessionId, {this.off = false});

  final String bindingId;

  /// Her conversation it was made for. Once bound, that conversation never
  /// goes back to ordinary chat: switching off means a new one.
  final String sessionId;

  /// Switched off (revoked) while the page could not yet replace the
  /// conversation; the next visit to that host does.
  final bool off;

  Map<String, Object?> toJson() => {'binding': bindingId, 'session': sessionId, if (off) 'off': true};

  static CompanionRecallRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final binding = json['binding'], session = json['session'];
    if (binding is! String || !_uuid.hasMatch(binding) || session is! String || session.isEmpty) return null;
    return CompanionRecallRecord(binding, session, off: json['off'] == true);
  }
}

Map<String, Object?> _all(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(_bindingsKey);
    final map = raw == null ? null : jsonDecode(raw);
    return map is Map ? {for (final e in map.entries) '${e.key}': e.value} : {};
  } on FormatException {
    return {};
  }
}

/// The binding this phone made on the host [hostKey], if any.
Future<CompanionRecallRecord?> companionRecallStored(String hostKey) async {
  final prefs = await SharedPreferences.getInstance();
  return CompanionRecallRecord.fromJson(_all(prefs)[hostKey]);
}

Future<void> companionRecallSave(String hostKey, CompanionRecallRecord record) async {
  final prefs = await SharedPreferences.getInstance();
  final all = _all(prefs);
  all[hostKey] = record.toJson();
  await prefs.setString(_bindingsKey, jsonEncode(all));
}

/// Forgets [bindingId] on [hostKey], and only that one: a newer binding made
/// meanwhile stays.
Future<void> companionRecallClear(String hostKey, String bindingId) async {
  final prefs = await SharedPreferences.getInstance();
  final all = _all(prefs);
  if (CompanionRecallRecord.fromJson(all[hostKey])?.bindingId != bindingId) return;
  all.remove(hostKey);
  await prefs.setString(_bindingsKey, jsonEncode(all));
}

/// One id per installation, made the first time it is needed.
Future<String> companionRecallConsumerId() async {
  final prefs = await SharedPreferences.getInstance();
  final known = prefs.getString(_consumerKey);
  if (known != null && _uuid.hasMatch(known)) return known;
  final id = newCompanionRecallId();
  await prefs.setString(_consumerKey, id);
  return id;
}
