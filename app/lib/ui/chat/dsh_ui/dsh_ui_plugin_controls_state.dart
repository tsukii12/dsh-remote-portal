// Local drafts for view v2. Remote data is authoritative for clean fields;
// edits made after a request starts always survive that request's response.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../l10n/l10n.dart';
import 'dsh_ui_bind.dart';
import 'dsh_ui_model.dart';
import 'dsh_ui_plugin.dart';

class _Draft {
  _Draft(this.value, this.revision);
  final Object? value;
  final int revision;
  bool clean = false;
}

class _Request {
  _Request(this.action, this.revisions, this.bindings);
  final PluginAction action;
  final Map<String, int> revisions;
  final List<String> bindings;
  final done = Completer<bool>();
}

/// The 250 ms interval matches the existing native data channel's 4 Hz policy.
/// It is a rate policy, not a claimed device latency measurement.
class PluginDraftController extends ChangeNotifier {
  PluginDraftController({Object? data, DateTime Function()? clock}) : _remote = data, _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const changeInterval = Duration(milliseconds: 250);
  static const maxQueuedRequests = 120;
  Object? _remote;
  Object? get remote => _remote;
  PluginActionHandler? handler;
  bool _disposed = false;
  bool _draining = false;
  Timer? _changeCooldown;
  int _revision = 0;
  int _actionSequence = 0;
  int _remoteRevision = 0;
  final _drafts = <String, _Draft>{};
  final _inputs = <String, DshUiInput>{};
  final _timers = <String, Timer>{};
  final _changedRemotely = <String, int>{};
  final _queue = <String, _Request>{};
  final _busy = <String>{};
  final errors = <String, String>{};
  final formErrors = <String, String>{};

  bool get enabled => !_disposed && handler != null;
  bool busy(String path) => _busy.contains(path);
  bool dirty(String bind) => _drafts[bind]?.clean == false;

  Object? value(DshUiInput input) {
    final draft = _drafts[input.bind];
    return draft == null ? input.value : draft.value;
  }

  /// Called while rebuilding, so it intentionally does not notify listeners.
  void syncRemote(Object? data) {
    if (identical(_remote, data)) return;
    final previous = _remote;
    _remote = data;
    _remoteRevision++;
    for (final binding in _inputs.keys) {
      final path = dshUiInputPath(binding)!;
      if (!_same(dshUiLookup(previous, path), dshUiLookup(data, path))) {
        _changedRemotely[binding] = _remoteRevision;
        if (_drafts[binding]?.clean == true) _drafts.remove(binding);
      }
    }
  }

  /// Only the currently parsed (therefore budgeted) inputs can retain state.
  void syncInputs(Iterable<DshUiInput> inputs) {
    _inputs
      ..clear()
      ..addEntries(inputs.where((i) => i.bind != null).map((i) => MapEntry(i.bind!, i)));
    for (final binding in _drafts.keys.toList()) {
      if (!_inputs.containsKey(binding)) _drafts.remove(binding);
    }
    for (final binding in _timers.keys.toList()) {
      if (!_inputs.containsKey(binding)) _timers.remove(binding)?.cancel();
    }
    errors.removeWhere((binding, _) => !_inputs.containsKey(binding));
    _changedRemotely.removeWhere((binding, _) => !_inputs.containsKey(binding));
    for (final key in _queue.keys.toList()) {
      final request = _queue[key]!;
      if (request.bindings.any((binding) => !_inputs.containsKey(binding))) {
        _queue.remove(key)!.done.complete(false);
      }
    }
  }

  /// Copy only paths being edited. The source and plugin-owned objects are
  /// never mutated; writable paths cannot create arbitrarily large arrays.
  Object? get data {
    Object? out = _remote;
    for (final entry in _drafts.entries) {
      out = _write(out, dshUiInputPath(entry.key)!, 0, entry.value.value);
    }
    return out;
  }

  void edit(DshUiInput input, Object? value) {
    final binding = input.bind;
    if (!enabled || input.readOnly || binding == null || !_inputs.containsKey(binding)) {
      return;
    }
    if (value is String) {
      final runes = value.runes.take(input.maxLength + 1).toList();
      if (runes.length > input.maxLength) value = String.fromCharCodes(runes.take(input.maxLength));
    }
    _drafts[binding] = _Draft(value, ++_revision);
    errors.remove(binding);
    formErrors.clear();
    _timers.remove(binding)?.cancel();
    if (input.onChange != null) {
      _timers[binding] = Timer(changeInterval, () {
        _timers.remove(binding);
        if (_disposed || !enabled) return;
        final latest = _inputs[binding];
        if (latest == null) return;
        final current = this.value(latest);
        final error = latest.validate(current);
        if (error != null) {
          errors[binding] = error;
          notifyListeners();
          return;
        }
        final action = latest.onChange;
        if (action == null) return;
        final args = <String, Object?>{...action.args, 'bind': binding, 'value': latest.submitted(current)};
        if (!_fits(args)) {
          errors[binding] = appL10n.plugInputTooLarge;
          notifyListeners();
          return;
        }
        unawaited(
          _enqueue(
            'change:$binding',
            PluginAction(id: action.id, args: args, source: PluginActionSource.change, path: latest.path),
            [binding],
          ),
        );
      });
    }
    notifyListeners();
  }

  Future<bool> submit(DshUiControlContainer form) async {
    final gestureAt = _clock();
    if (!enabled || _busy.contains(form.path) || form.submit == null) {
      return false;
    }
    final inputs = form.inputs.where((i) => i.bind != null && !i.readOnly).toList();
    final values = <String, Object?>{};
    var valid = true;
    for (final input in inputs) {
      final binding = input.bind!;
      final current = value(input);
      final error = input.validate(current);
      if (error != null) {
        errors[binding] = error;
        valid = false;
      } else {
        errors.remove(binding);
        values[binding] = input.submitted(current);
      }
    }
    if (!valid) {
      formErrors[form.path] = appL10n.plugInputCheckFields;
      notifyListeners();
      return false;
    }
    final args = <String, Object?>{...form.submit!.args, 'values': values};
    if (!_fits(args)) {
      formErrors[form.path] = appL10n.plugInputTooLarge;
      notifyListeners();
      return false;
    }
    // The submit carries these latest values. Drop changes not yet dispatched;
    // an already running request completes before this submit is sent.
    for (final binding in values.keys) {
      _timers.remove(binding)?.cancel();
      _queue.remove('change:$binding')?.done.complete(false);
    }
    formErrors.remove(form.path);
    _busy.add(form.path);
    notifyListeners();
    final ok = await _enqueue(
      'submit:${form.path}',
      PluginAction(
        id: form.submit!.id,
        args: args,
        source: PluginActionSource.submit,
        path: form.path,
        gestureAt: gestureAt,
      ),
      values.keys.toList(),
    );
    if (!_disposed) {
      _busy.remove(form.path);
      if (!ok) formErrors[form.path] = appL10n.plugInputFailed;
      notifyListeners();
    }
    return ok;
  }

  /// v2 buttons share the same lane as changes and submits. There is never an
  /// older local invoke response arriving after a newer local invoke response.
  Future<bool> invoke(PluginAction action) {
    final stamped = action.source == PluginActionSource.change || action.gestureAt != null
        ? action
        : action.withGestureAt(_clock());
    return _enqueue('action:${++_actionSequence}:${action.path}', stamped, const []);
  }

  Future<bool> _enqueue(String key, PluginAction action, List<String> bindings) {
    if (!enabled) return Future.value(false);
    if (!_queue.containsKey(key) && _queue.length >= maxQueuedRequests) {
      for (final binding in bindings) {
        errors[binding] = appL10n.plugInputFailed;
      }
      notifyListeners();
      return Future.value(false);
    }
    final request = _Request(action, {for (final b in bindings) b: _drafts[b]?.revision ?? 0}, bindings);
    final replaced = _queue[key];
    if (replaced != null) replaced.done.complete(false);
    _queue[key] = request;
    unawaited(_drain());
    return request.done.future;
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        var key = _queue.keys.first;
        if (_changeCooldown != null && _queue[key]!.action.source == PluginActionSource.change) {
          // Explicit submit/tap need not wait for a change rate slot. A submit
          // already removed queued changes for its own fields.
          final explicit = _queue.entries.where((e) => e.value.action.source != PluginActionSource.change).firstOrNull;
          if (explicit == null) break;
          key = explicit.key;
        }
        final request = _queue.remove(key)!;
        if (request.action.source == PluginActionSource.change) {
          _changeCooldown = Timer(changeInterval, () {
            _changeCooldown = null;
            if (!_disposed) unawaited(_drain());
          });
        }
        final remoteAtSend = _remoteRevision;
        var ok = false;
        final send = handler;
        if (send != null) {
          try {
            ok = await send(request.action);
          } catch (_) {
            ok = false;
          }
        }
        if (_disposed) {
          request.done.complete(false);
          break;
        }
        for (final binding in request.bindings) {
          final draft = _drafts[binding];
          // A later keystroke belongs to the next request, never this one.
          if (draft == null || draft.revision != request.revisions[binding]) {
            continue;
          }
          if (ok) {
            errors.remove(binding);
            if ((_changedRemotely[binding] ?? 0) > remoteAtSend) {
              _drafts.remove(binding);
            } else {
              draft.clean = true;
            }
          } else {
            errors[binding] = appL10n.plugInputFailed;
          }
        }
        request.done.complete(ok);
        notifyListeners();
      }
    } finally {
      _draining = false;
    }
  }

  /// Disconnects stop pending changes without retrying actions automatically.
  void setHandler(PluginActionHandler? next) {
    handler = next;
    if (next != null) return;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _changeCooldown?.cancel();
    _changeCooldown = null;
    for (final request in _queue.values) {
      request.done.complete(false);
    }
    _queue.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    setHandler(null);
    super.dispose();
  }
}

bool _fits(Object value) => measureDshUiJson(value, maxBytes: DshUiControlLimits.valueBytes).ok;

Object? _write(Object? value, List<String> parts, int index, Object? leaf) {
  if (index == parts.length) return leaf;
  final map = value is Map
      ? <String, Object?>{for (final e in value.entries) '${e.key}': e.value}
      : <String, Object?>{};
  map[parts[index]] = _write(map[parts[index]], parts, index + 1, leaf);
  return map;
}

bool _same(Object? a, Object? b) {
  if (a is List && b is List) return listEquals(a, b);
  return a == b;
}
