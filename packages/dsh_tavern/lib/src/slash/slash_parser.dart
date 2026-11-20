// Fixed default (non-strict) SlashCommandParser delimiter state, not a global
// backslash-parity lexer. Port source is identified by slash_language.dart.
part of 'slash_language.dart';

class SlashParser {
  SlashParser(this.source, {required this.checkCancelled});
  final SlashSource source;
  final void Function() checkCancelled;
  String get text => source.text;
  int _index = 0, _work = 0, _macroScan = 0, _macroDepth = 0;
  bool _jumped = false;
  int _depth = 0;
  Future<void> _tick() async {
    if (_work < 4096) return;
    _work = 0;
    checkCancelled();
    await Future<void>.delayed(Duration.zero);
    checkCancelled();
  }

  void _consumed() {
    _work++;
    // Keep at most the last consumed code unit pending. This recognizes each
    // complete brace pair without rescanning the entire prefix at a pipe.
    while (_macroScan + 1 < _index) {
      if (text.startsWith('{{', _macroScan)) {
        _macroDepth++;
        _macroScan += 2;
        _work += 2;
      } else if (text.startsWith('}}', _macroScan)) {
        if (_macroDepth > 0) _macroDepth--;
        _macroScan += 2;
        _work += 2;
      } else {
        _macroScan++;
        _work++;
      }
    }
  }

  String _take([int length = 1]) {
    _jumped = false;
    var value = '';
    for (var count = 0; count < length && _index < text.length; count++) {
      value = text[_index++];
      _consumed();
    }
    return value;
  }

  bool _symbol(String symbol, [int offset = 0]) {
    final at = _index + offset + (_jumped ? -1 : 0);
    if (at < 0 || at >= text.length) return false;
    final escaped = text[at] == r'\';
    if (!text.startsWith(symbol, at + (escaped ? 1 : 0))) return false;
    if (!escaped) return true;
    if (!_jumped && offset == 0) {
      _index++;
      _consumed();
      _jumped = true;
    }
    return false;
  }

  bool _whitespaceSymbol() {
    final at = _index + (_jumped ? -1 : 0);
    if (at < 0 || at >= text.length) return false;
    final escaped = text[at] == r'\';
    final next = at + (escaped ? 1 : 0);
    if (next >= text.length || !isJsWhitespace(text.codeUnitAt(next))) return false;
    if (!escaped) return true;
    if (!_jumped) {
      _index++;
      _consumed();
      _jumped = true;
    }
    return false;
  }

  Future<void> _whitespace() async {
    while (_index < text.length && isJsWhitespace(text.codeUnitAt(_index))) {
      _take();
      await _tick();
    }
  }

  Never _syntax(String message, [int? at]) => throw _languageError(
    TavernScriptErrorCode.invalidArgument,
    'parse',
    message,
    source.span(at ?? _index, at ?? _index),
  );
  bool _closureEnd() {
    if (_depth == 0) return _index >= text.length;
    if (_index + 1 >= text.length) _syntax('Unclosed closure.');
    return _symbol(':}');
  }

  bool _insideMacro() => _macroDepth > 0;
  bool _end() => _closureEnd() || (_symbol('|') && !_insideMacro());
  bool _word(int code) =>
      code >= 48 && code <= 57 || code >= 65 && code <= 90 || code == 95 || code >= 97 && code <= 122;
  Future<bool> _named() async {
    var at = _index;
    if (at >= text.length || !_word(text.codeUnitAt(at))) return false;
    do {
      at++;
      _work++;
      await _tick();
    } while (at < text.length && _word(text.codeUnitAt(at)));
    return at < text.length && text.codeUnitAt(at) == 61;
  }

  Future<SlashProgram> parse() async {
    checkCancelled();
    await source.prepareLineIndex(checkCancelled);
    checkCancelled();
    final program = await _program(root: true);
    await _tick();
    checkCancelled();
    return program;
  }

  Future<SlashProgram> _program({bool root = false}) async {
    final start = _index;
    if (!root) {
      _take(2);
      _depth++;
    }
    final defaults = <SlashAssignment>[];
    final commands = <SlashNode>[];
    var injectPipe = true;
    await _whitespace();
    while (await _named()) {
      defaults.add(await _assignment());
      await _whitespace();
    }
    while (!_closureEnd()) {
      await _tick();
      if (_symbol('/*')) {
        await _blockComment();
      } else if (_symbol('//') || _symbol('/#')) {
        _take(2);
        while (!_symbol('|')) {
          if (_index >= text.length) _syntax('Unclosed comment.');
          _take();
          await _tick();
        }
      } else if (_symbol('/:') && !_symbol(':}', 1)) {
        commands.add(await _shorthand());
        injectPipe = true;
      } else if (_symbol('/')) {
        final command = await _command(injectPipe);
        commands.add(command);
        // The special break node does not consume the pending || setting.
        if (command.name != 'break') injectPipe = true;
      } else {
        while (!_end()) {
          _take();
          await _tick();
        }
      }
      await _whitespace();
      if (_symbol('|')) {
        _take();
        if (_symbol('|')) {
          injectPipe = false;
          _take();
        }
      }
      await _whitespace();
    }
    if (!root) {
      _take(2);
      _depth--;
    }
    var executeNow = false;
    if (_symbol('()')) {
      _take(2);
      executeNow = true;
    }
    return SlashProgram(
      source: source,
      span: source.span(start, _index),
      defaults: defaults,
      commands: commands,
      executeNow: executeNow,
    );
  }

  Future<void> _blockComment() async {
    _take(2);
    var levels = 1;
    while (levels > 0) {
      await _tick();
      if (_index + 1 >= text.length) _syntax('Unclosed block comment.');
      if (_symbol('*|')) {
        _take(2);
        levels--;
        if (levels == 0) return;
        // A completed child returns to the parent's unconditional take().
        _take();
      } else if (_symbol('/*')) {
        _take(2);
        levels++;
      } else {
        _take();
      }
      await _tick();
    }
  }

  Future<SlashNode> _shorthand() async {
    final start = _index;
    _take(2);
    final valueStart = _index;
    final quoted = _symbol('"');
    final value = quoted ? await _quoted() : await _value();
    final unnamed = [SlashAssignment(value: value, span: source.span(valueStart, _index), quoted: quoted)];
    await _whitespace();
    final named = <SlashAssignment>[];
    while (await _named()) {
      named.add(await _assignment());
      await _whitespace();
    }
    if (!_end()) _syntax('Unexpected text after run shorthand.');
    return SlashNode(name: 'run', span: source.span(start, _index), named: named, unnamed: unnamed, shorthand: true);
  }

  Future<SlashNode> _command(bool injectPipe) async {
    final start = _index;
    _take();
    final name = StringBuffer();
    while (_index < text.length && !isJsWhitespace(text.codeUnitAt(_index)) && !_end()) {
      name.write(_take());
      await _tick();
    }
    final spelling = name.toString();
    if (spelling == 'parser-flag') {
      throw _languageError(
        TavernScriptErrorCode.unsupportedOption,
        'parse',
        'Parser flags are not supported.',
        source.span(start, _index),
      );
    }
    await _whitespace();
    final named = <SlashAssignment>[];
    if (spelling != 'break') {
      while (await _named()) {
        named.add(await _assignment());
        await _whitespace();
      }
    }
    final descriptor = slashDescriptors[spelling];
    var rawQuotes = descriptor?.rawQuotes == true;
    if (rawQuotes) {
      for (final arg in named) {
        if (arg.name == 'raw') {
          rawQuotes = !ScriptCoercion.falseBoolean(arg.value is String ? arg.value! as String : '[Closure]');
          break;
        }
      }
    }
    final unnamed = _end()
        ? <SlashAssignment>[]
        : await _unnamed(
            split: descriptor?.splitUnnamed == true,
            splitCount: descriptor?.splitCount,
            rawQuotes: rawQuotes,
          );
    if (!_end()) _syntax('Unexpected end of command.');
    return SlashNode(
      name: spelling,
      span: source.span(start, _index),
      named: named,
      unnamed: unnamed,
      injectPipe: spelling == 'break' ? true : injectPipe,
    );
  }

  Future<SlashAssignment> _assignment() async {
    final start = _index;
    final key = StringBuffer();
    while (_index < text.length && _word(text.codeUnitAt(_index))) {
      key.write(_take());
      await _tick();
    }
    _take();
    Object? value = ScriptCoercion.undefined;
    var quoted = false;
    if (_symbol('{:')) {
      value = await _program();
    } else if (_symbol('"')) {
      quoted = true;
      value = await _quoted();
    } else if (_symbol('[')) {
      value = await _list();
    } else if (!_whitespaceSymbol() && !_end()) {
      value = await _value();
    }
    return SlashAssignment(name: key.toString(), value: value, span: source.span(start, _index), quoted: quoted);
  }

  Future<String> _quoted() async {
    _take();
    final value = StringBuffer();
    while (true) {
      if (_index >= text.length || _end()) _syntax('Unexpected end of quoted value.');
      if (_symbol('"')) {
        _take();
        return value.toString();
      }
      value.write(_take());
      await _tick();
    }
  }

  Future<String> _list() async {
    final value = StringBuffer(_take());
    while (true) {
      if (_index >= text.length) _syntax('Unexpected end of list value.');
      if (_symbol(']')) {
        value.write(_take());
        return value.toString();
      }
      value.write(_take());
      await _tick();
    }
  }

  Future<String> _value() async {
    final value = StringBuffer(_jumped ? _take() : '');
    while (!_whitespaceSymbol() && !_end()) {
      value.write(_take());
      await _tick();
    }
    return value.toString();
  }

  Future<List<SlashAssignment>> _unnamed({required bool split, int? splitCount, required bool rawQuotes}) async {
    final wasSplit = split;
    var value = StringBuffer(_jumped ? _take() : '');
    var isList = split;
    final values = <SlashAssignment>[];
    final quotedFlags = <bool>[];
    var start = _index;
    void add(Object? item, {bool? quoted}) {
      values.add(SlashAssignment(value: item, span: source.span(start, _index), quoted: quoted == true));
      if (quoted != null) quotedFlags.add(quoted);
      start = _index;
    }

    if (!split && !rawQuotes && _symbol('"')) {
      add(await _quoted(), quoted: true);
      isList = true;
    }
    while (!_end()) {
      await _tick();
      if (split && splitCount != null && splitCount != 0 && values.length >= splitCount) {
        split = false;
        if (_symbol('"')) add(await _quoted(), quoted: true);
      }
      if (_symbol('{:')) {
        isList = true;
        if (value.isNotEmpty) {
          add(value.toString(), quoted: false);
          value = StringBuffer();
        }
        start = _index;
        add(await _program());
        if (split) await _whitespace();
      } else if (split) {
        start = _index;
        if (_symbol('"')) {
          add(await _quoted(), quoted: true);
        } else if (_symbol('[')) {
          add(await _list(), quoted: false);
        } else if (!_whitespaceSymbol()) {
          add(await _value(), quoted: false);
        } else {
          _syntax('Unexpected end of unnamed argument.');
        }
        await _whitespace();
      } else {
        value.write(_take());
      }
    }
    if (!isList) {
      return [SlashAssignment(value: trimJsWhitespace(value.toString()), span: source.span(start, _index))];
    }
    if (value.isNotEmpty) add(value.toString(), quoted: false);
    if (values.isNotEmpty && values.first.value is String) {
      final first = values.first;
      final text = quotedFlags.isNotEmpty && quotedFlags.first
          ? first.value! as String
          : trimStartJsWhitespace(first.value! as String);
      if (text.isEmpty) {
        values.removeAt(0);
        if (quotedFlags.isNotEmpty) quotedFlags.removeAt(0);
      } else {
        values[0] = SlashAssignment(value: text, span: first.span, quoted: first.quoted);
      }
    }
    if (values.isNotEmpty && values.last.value is String) {
      final last = values.last;
      final text = quotedFlags.isNotEmpty && quotedFlags.last
          ? last.value! as String
          : trimEndJsWhitespace(last.value! as String);
      if (text.isEmpty) {
        values.removeLast();
        if (quotedFlags.isNotEmpty) quotedFlags.removeLast();
      } else {
        values[values.length - 1] = SlashAssignment(value: text, span: last.span, quoted: last.quoted);
      }
    }
    if (wasSplit && splitCount != null && splitCount != 0 && splitCount + 1 < values.length) {
      final joined = StringBuffer();
      for (var i = splitCount; i < values.length; i++) {
        final item = values[i].value;
        final text = item is SlashProgram ? '[Closure]' : ScriptCoercion.string(item);
        joined.write(i < quotedFlags.length && quotedFlags[i] ? '"$text"' : text);
      }
      final span = source.span(values[splitCount].span.start, values.last.span.end);
      return [...values.take(splitCount), SlashAssignment(value: joined.toString(), span: span)];
    }
    return values;
  }
}
