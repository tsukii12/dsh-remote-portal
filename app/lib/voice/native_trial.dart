// Native code that crashes takes the app with it: Dart catches nothing of a
// SIGILL. The first time the streaming recognizer runs on this phone, a mark is
// written down first and cleared once it has decoded; a mark still there at the
// next try means the app died in there, and live words stay off on this phone.
// The marks sit with the model: deleting it and downloading again tries anew.

import 'dart:io';

class NativeTrial {
  NativeTrial(this.directory, this.key);

  final Directory directory;

  /// What is being tried (the ONNX Runtime the recognizer brings).
  final String key;

  File _mark(String kind) => File('${directory.path}/.trial-$key.$kind');

  /// It died here before, or the last try never came back (which is decided now).
  bool blocked() {
    if (_mark('bad').existsSync()) return true;
    final trying = _mark('trying');
    if (!trying.existsSync()) return false;
    _mark('bad').writeAsStringSync('', flush: true);
    trying.deleteSync();
    return true;
  }

  /// As [blocked], deciding nothing: for showing, while no try is running.
  bool get failed => _mark('bad').existsSync() || _mark('trying').existsSync();

  /// It has run here before: no mark needed.
  bool get proven => _mark('ok').existsSync();

  void begin() {
    directory.createSync(recursive: true);
    _mark('trying').writeAsStringSync('', flush: true);
  }

  void passed() {
    _mark('ok').writeAsStringSync('', flush: true);
    dropped();
  }

  /// Ended without a verdict (stopped first, or an error Dart did catch): try again next time.
  void dropped() {
    final trying = _mark('trying');
    if (trying.existsSync()) trying.deleteSync();
  }
}

/// Live words were not started: the recognizer once crashed the app on this phone.
class LiveWordsBlocked implements Exception {
  const LiveWordsBlocked();
}
