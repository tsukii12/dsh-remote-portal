// Persona precedence follows SillyTavern 1.19.0 public/scripts/personas.js,
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../persona.dart';
import 'chat_store.dart';

/// Owns profiles and their global default in one versioned JSON document.
/// Chat bindings remain in [ChatStore]. Use one owner per tavern directory.
///
/// Each queued write reads the latest committed document, flushes a temporary
/// file, renames it, and only then publishes its in-memory state and event.
/// Callers must serialize chat mutations against active turns in the facade.
class PersonaStore {
  PersonaStore._(this._file, this._document, this._createId);

  /// [tavernDirectory] is already the tavern root, not its parent.
  static Future<PersonaStore> open(Directory tavernDirectory, {String Function()? createId}) async {
    final file = File('${tavernDirectory.path}/personas/index.json');
    String? text;
    try {
      // A type lookup can report notFound for access errors; read the source.
      text = await file.readAsString();
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
      // Opening a known non-file can also report a missing path.
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.notFound) rethrow;
    }
    final document = text == null
        ? <String, Object?>{'version': 1, 'personas': <Object?>[], 'defaultPersonaId': null}
        : _decode(text);
    _validate(document);
    return PersonaStore._(file, document, createId ?? _newId);
  }

  final File _file;
  final String Function() _createId;
  Map<String, Object?> _document;
  Object _authoringVersion = Object();
  final _changes = StreamController<void>.broadcast();
  Future<void> _queue = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _closed = false;

  Stream<void> get changes => _changes.stream;

  /// Opaque identity of the last adopted profile document. It exposes no
  /// document data and changes only after the file replacement succeeds.
  Object get authoringVersion {
    _ensureOpen();
    return _authoringVersion;
  }

  /// Returned models and their JSON documents do not alias stored data.
  List<TavernPersona> list() {
    _ensureOpen();
    return List<TavernPersona>.unmodifiable(_records(_document).map(TavernPersona.fromJson));
  }

  TavernPersona? get(String id) {
    _ensureOpen();
    return _find(_document, id);
  }

  String? get defaultPersonaId {
    _ensureOpen();
    return _document['defaultPersonaId'] as String?;
  }

  /// Chat binding > global default > none. A missing binding is ignored.
  /// Capturing this immutable result before a turn makes later profile edits
  /// take effect on the next turn without changing an in-flight request.
  PersonaSelection resolve({String? personaId}) {
    _ensureOpen();
    final bound = personaId == null ? null : _find(_document, personaId);
    final defaultId = _document['defaultPersonaId'] as String?;
    final fallback = defaultId == null ? null : _find(_document, defaultId);
    return PersonaSelection(
      persona: bound ?? fallback,
      source: bound != null
          ? PersonaSelectionSource.chat
          : fallback != null
          ? PersonaSelectionSource.globalDefault
          : PersonaSelectionSource.none,
      boundPersonaId: bound?.id,
      defaultPersonaId: fallback?.id,
    );
  }

  PersonaSelection forChat(ChatStore chats, String chatId) => resolve(personaId: chats.chat(chatId).personaId);

  Future<TavernPersona> create({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) => _enqueue(() async {
    final id = _createId();
    if (_find(_document, id) != null) {
      throw StateError('Persona id already exists: $id');
    }
    final persona = TavernPersona(
      id: id,
      name: name,
      description: description,
      avatarPath: avatarPath,
      descriptionPosition: descriptionPosition,
    );
    final next = _copy(_document);
    _records(next).add(persona.toJson());
    await _persist(next);
    _notify();
    return persona;
  });

  /// Only provided fields change. An empty string is a real replacement;
  /// [clearAvatar] explicitly clears an existing avatar reference.
  Future<TavernPersona> update(
    String id, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) => _enqueue(() async {
    final current = _find(_document, id);
    if (current == null) throw StateError('Unknown persona: $id');
    final persona = current.copyWith(
      name: name,
      description: description,
      avatarPath: avatarPath,
      clearAvatar: clearAvatar,
      descriptionPosition: descriptionPosition,
    );
    final next = _copy(_document);
    final records = _records(next);
    records[records.indexWhere((record) => record['id'] == id)] = persona.toJson();
    await _persist(next);
    _notify();
    return persona;
  });

  /// A null id removes the default; unbound chats then have no selected profile.
  Future<void> setDefault(String? id) => _enqueue(() async {
    if (id != null && _find(_document, id) == null) {
      throw StateError('Unknown persona: $id');
    }
    if (_document['defaultPersonaId'] == id) return;
    final next = _copy(_document)..['defaultPersonaId'] = id;
    await _persist(next);
    _notify();
  });

  /// A null id means inherit the global default. This updates chat settings,
  /// never the speaker or text of already stored messages.
  Future<void> bindChat(ChatStore chats, String chatId, String? personaId) => _enqueue(() async {
    if (personaId != null && _find(_document, personaId) == null) {
      throw StateError('Unknown persona: $personaId');
    }
    final chat = chats.chat(chatId);
    if (chat.personaId == personaId) return;
    chats.updateChat(chatId, personaId: personaId, clearPersona: personaId == null);
    _notify();
  });

  /// Removes a profile and clears all matching chat bindings. The caller owns
  /// the active-turn barrier. The optional avatar file remains untouched.
  ///
  /// Profile/default deletion commits together; clearing SQLite references is
  /// a second commit. A crash between them can leave dangling bindings, which
  /// [resolve] ignores safely. Calling delete again also cleans these references
  /// when the profile is already absent. Failures propagate to the caller.
  Future<bool> delete(String id, {required ChatStore chats}) => _enqueue(() async {
    // Validate the database owner before starting the file commit.
    chats.listChatPersonaBindings();
    final existed = _find(_document, id) != null;
    var changed = false;
    if (existed || _document['defaultPersonaId'] == id) {
      final next = _copy(_document);
      _records(next).removeWhere((record) => record['id'] == id);
      if (next['defaultPersonaId'] == id) next['defaultPersonaId'] = null;
      await _persist(next);
      changed = true;
    }
    try {
      final affected = chats.listChatPersonaBindings().where((chat) => chat.personaId == id).toList();
      if (affected.isNotEmpty) {
        chats.transaction(() {
          for (final chat in affected) {
            chats.updateChat(chat.id, clearPersona: true);
          }
        });
        changed = true;
      }
      return existed;
    } finally {
      // Observers must see a committed file change even if SQLite cleanup fails.
      if (changed) _notify();
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    _ensureOpen();
    final result = _queue.then((_) => operation());
    // One failed operation must not prevent later independent writes.
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _persist(Map<String, Object?> next) async {
    _validate(next);
    final encoded = jsonEncode(next);
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.writing');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(_file.path);
    _document = next;
    _authoringVersion = Object();
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void _ensureOpen() {
    if (_closing || _closed) throw StateError('PersonaStore is closed.');
  }

  /// Drains queued writes. Paused notification listeners do not hold the owner
  /// open. The facade should close this store before closing its ChatStore.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _queue;
    _closed = true;
    unawaited(_changes.close());
  }

  static Map<String, Object?> _decode(String text) {
    final decoded = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Persona index must be a JSON object.');
    }
    return decoded;
  }

  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, Object?>;

  static List<Map<String, Object?>> _records(Map<String, Object?> document) =>
      (document['personas']! as List<Object?>).cast<Map<String, Object?>>();

  static TavernPersona? _find(Map<String, Object?> document, String id) {
    for (final record in _records(document)) {
      if (record['id'] == id) return TavernPersona.fromJson(record);
    }
    return null;
  }

  static void _validate(Map<String, Object?> document) {
    if (document['version'] != 1) {
      throw FormatException('Unsupported persona index version: ${document['version']}');
    }
    final raw = document['personas'];
    if (raw is! List<Object?>) {
      throw const FormatException('Persona index must contain a personas array.');
    }
    final ids = <String>{};
    for (final value in raw) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Each persona must be a JSON object.');
      }
      final persona = TavernPersona.fromJson(value);
      if (!ids.add(persona.id)) {
        throw FormatException('Duplicate persona id: ${persona.id}');
      }
    }
    final defaultId = document['defaultPersonaId'];
    if (defaultId != null && (defaultId is! String || !ids.contains(defaultId))) {
      throw const FormatException('Default persona must refer to an existing profile.');
    }
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
