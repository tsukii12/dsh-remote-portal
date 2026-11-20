// Persistent Slash injection commands adapt SillyTavern slash-commands.js
// 3773–3887 at 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// These entries are selected-source chat metadata, never transient leases.
part of 'engine.dart';

Map<String, Object?> _slashPersistentInjections(_SlashInvocation invocation, Map<String, Object?> metadata) {
  if (!metadata.containsKey('script_injects')) return <String, Object?>{};
  final value = metadata['script_injects'];
  if (value is! Map<String, Object?>) {
    throw _slashArgument(
      invocation,
      'metadata.script_injects',
      'The persistent injection container must be an object.',
      code: TavernScriptErrorCode.shapeMismatch,
    );
  }
  return _captureScriptObject(value);
}

String _slashInjectionListing(_SlashInvocation invocation, Map<String, Object?> entries) {
  final lines = <String>[];
  // The same JS own-key enumeration used by the fixed Fuse consumer also
  // governs Object.entries: numeric property names precede ordinary names.
  for (final rawId in stObjectValues({for (final id in entries.keys) id: id})) {
    final id = rawId! as String;
    final entry = entries[id];
    if (entry == null) {
      throw _slashArgument(
        invocation,
        'metadata.script_injects.$id',
        'A null injection has no listing fields.',
        code: TavernScriptErrorCode.shapeMismatch,
      );
    }
    Object? property(String key) =>
        entry is Map<String, Object?> && entry.containsKey(key) ? entry[key] : ScriptCoercion.undefined;
    Object? fallback(Object? value, Object? otherwise) =>
        value == null || ScriptCoercion.isUndefined(value) ? otherwise : value;
    final position = switch (property('position')) {
      -1 => 'NONE',
      0 => 'IN_PROMPT',
      1 => 'IN_CHAT',
      2 => 'BEFORE_PROMPT',
      _ => 'unknown',
    };
    lines.add(
      '* **$id**: <code>${ScriptCoercion.string(property('value'))}</code> '
      '($position, depth: ${ScriptCoercion.string(property('depth'))}, '
      'scan: ${ScriptCoercion.string(fallback(property('scan'), false))}, '
      'role: ${ScriptCoercion.string(fallback(property('role'), 0))})',
    );
  }
  return '### Script injections:\n${lines.isEmpty ? 'No script injections for the current chat' : lines.join('\n')}';
}

extension _SlashPersistentInjectionOperations on _ScriptCoordinator {
  Future<String> _executeSlashPersistentInjection(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    final operation = invocation.command;
    if (operation == 'listinjects') {
      final mode = _slashReturnMode(invocation, fallback: 'popup-html');
      final admission = await _captureSlashChat(owner);
      owner.checkAlive();
      final entries = _slashPersistentInjections(invocation, admission.metadata);
      final text = _slashInjectionListing(invocation, entries);
      return _returnSlashValue(invocation, mode, text: text, object: entries);
    }

    final body = _slashBody(invocation);
    String? id;
    Map<String, Object?>? replacement;
    if (operation == 'inject') {
      id = _slashNamed(invocation, 'id');
      if (id.isEmpty) id = _slashRequestId('persistentInjection');
      final position = switch (_slashNamed(invocation, 'position', fallback: 'after')) {
        'before' => 2,
        'after' => 0,
        'chat' => 1,
        'none' => -1,
        _ => throw _slashArgument(invocation, 'position', 'The injection position is invalid.'),
      };
      final role = switch (_slashNamed(invocation, 'role', fallback: 'system')) {
        'system' => 0,
        'user' => 1,
        'assistant' => 2,
        _ => throw _slashArgument(invocation, 'role', 'The injection role is invalid.'),
      };
      final depth = invocation.has('depth') ? ScriptCoercion.number(_slashNamed(invocation, 'depth')) : 4.0;
      if (!depth.isFinite || depth != depth.truncateToDouble() || depth < 0 || depth > 10000) {
        throw _slashArgument(invocation, 'depth', 'Injection depth must be an integer from 0 to 10000.');
      }
      final scan = _slashTrue(invocation, 'scan');
      if (body.isNotEmpty) {
        replacement = {
          'value': body,
          'position': position,
          'depth': depth.toInt(),
          'role': role,
          'scan': scan,
          'filter': '',
        };
      }
    }
    final admission = await _captureSlashChat(owner);
    owner.checkAlive();
    return _mutateSlashMetadata<String>(
      owner,
      admission,
      operation: operation,
      target: {'kind': 'chatState', 'chatId': admission.capture.chatId},
      transform: (metadata, settings) {
        final entries = _slashPersistentInjections(invocation, metadata);
        final affected = <String>{};
        if (operation == 'inject') {
          final key = id!;
          if (replacement != null) {
            entries[key] = _captureScriptObject(replacement);
            // Even an equal JSON replacement is a new persistent incarnation.
            affected.add(key);
          } else if (entries.containsKey(key)) {
            entries.remove(key);
            affected.add(key);
          }
        } else if (body.isEmpty) {
          affected.addAll(entries.keys);
          entries.clear();
        } else if (entries.containsKey(body)) {
          entries.remove(body);
          affected.add(body);
        }
        final changed = affected.isNotEmpty;
        if (changed) metadata['script_injects'] = entries;
        return (
          changed: changed,
          value: operation == 'inject' ? id! : '',
          metadata: metadata,
          settings: null,
          injectionIds: affected,
        );
      },
    );
  }
}
