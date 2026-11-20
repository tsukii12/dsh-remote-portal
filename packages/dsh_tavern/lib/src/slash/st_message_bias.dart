part of '../engine.dart';

// Handlebars 4.7.9 fresh-environment bias consumer.
// Source: handlebars-lang/handlebars.js, tag v4.7.9; ST 7e8663c,
// public/script.js 3140-3163. The backend deliberately uses the fallback
// SourceNode representation and source-declaration function arities. It does
// not expose browser globals or fabricate function source/name reflection.
//
// Copyright (C) 2011-2019 by Yehuda Katz
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to
// do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

String _slashExtractMessageBias(String text) {
  if (text.isEmpty) return '';
  try {
    final parsed = _HbParser(text).parse();
    _HbWhitespace().program(parsed);
    final compiled = _HbCompiler().compile(parsed);
    return _HbRuntime().extract(compiled);
  } on _HbFault {
    return '';
  } on StackOverflowError {
    // Recursive partials have the same whole-invocation failure boundary as
    // the fixed consumer's actual JavaScript stack overflow.
    return '';
  }
}

// Only errors established by the fixed parser/compiler/runtime use this
// channel. Deliberate structured reflection failures are never caught above.
final class _HbFault implements Exception {
  const _HbFault(this.message);
  final String message;
}

Never _hbFail(String message) => throw _HbFault(message);
Object get _hbUndefined => ScriptCoercion.undefined;
const Object _hbNotSupplied = Object();
bool _hbNullish(Object? value) => value == null || ScriptCoercion.isUndefined(value);
// proto-access.js owns this cache at module scope, outside Handlebars.create().
// Only primitive property keys are retained; no template objects escape a call.
final Set<String> _hbLoggedProperties = <String>{};

final class _HbSpan {
  const _HbSpan(this.start, this.end, this.line, this.column, this.endLine, this.endColumn)
    : sourceRuntime = null,
      sourceLocation = null;
  const _HbSpan.raw(this.sourceRuntime, this.sourceLocation)
    : start = 0,
      end = 0,
      line = 0,
      column = 0,
      endLine = 0,
      endColumn = 0;
  final int start, end, line, column, endLine, endColumn;
  final _HbRuntime? sourceRuntime;
  final Object? sourceLocation;
  _HbSpan through(_HbSpan other) => _HbSpan(start, other.end, line, column, other.endLine, other.endColumn);
}

final class _HbToken {
  const _HbToken(this.kind, this.text, this.span);
  final String kind, text;
  final _HbSpan span;
}

// This scanner implements the exclusive mu/emu/com/raw states of the fixed
// lexer. Strings intentionally unescape only their matching quote.
final class _HbLexer {
  _HbLexer(this.source);
  final String source;
  int offset = 0, line = 1, column = 0, rawDepth = 0;
  String mode = 'initial';

  bool _at(String value) => source.startsWith(value, offset);
  bool _space(int index) => index < source.length && isJsWhitespace(source.codeUnitAt(index));
  bool _look(int index, {bool literal = false}) {
    if (index >= source.length) return false;
    final c = source[index];
    return _space(index) || (literal ? '~})' : '=~}/.)|').contains(c);
  }

  bool _idUnit(int index) {
    final c = source.codeUnitAt(index);
    return !isJsWhitespace(c) &&
        c != 33 &&
        c != 34 &&
        c != 35 &&
        !(c >= 37 && c <= 44) &&
        c != 46 &&
        c != 47 &&
        !(c >= 59 && c <= 62) &&
        c != 64 &&
        !(c >= 91 && c <= 94) &&
        c != 96 &&
        !(c >= 123 && c <= 126);
  }

  _HbToken _take(String kind, int end, {String? text}) {
    final start = offset, startLine = line, startColumn = column;
    final original = source.substring(start, end);
    // The published 4.7.9 Jison lexer updates locations per matched token.
    // Its dot is not dotAll: preserve even the resulting U+2028/U+2029 tail
    // quirk instead of substituting a more conventional character counter.
    final lines = RegExp(r'(?:\r\n?|\n).*').allMatches(original).toList();
    if (lines.isEmpty) {
      column += original.length;
    } else {
      line += lines.length;
      final last = lines.last[0]!;
      column = last.length - RegExp(r'\r?\n?').firstMatch(last)!.group(0)!.length;
    }
    offset = end;
    return _HbToken(kind, text ?? original, _HbSpan(start, end, startLine, startColumn, line, column));
  }

  _HbToken next() {
    while (true) {
      if (offset == source.length) {
        if (mode == 'raw' || mode == 'escaped') _hbFail('Unclosed raw content');
        return _take('eof', offset);
      }
      if (mode == 'initial') {
        final open = source.indexOf('{{', offset);
        final nul = source.indexOf('\u0000', offset);
        if (nul == offset) _hbFail('Invalid content character');
        if (open < 0 || (nul >= 0 && nul < open)) {
          return _take('content', nul < 0 ? source.length : nul);
        }
        final content = source.substring(offset, open);
        var value = content;
        if (content.endsWith(r'\\')) {
          value = content.substring(0, content.length - 1);
          mode = 'mu';
        } else if (content.endsWith(r'\')) {
          value = content.substring(0, content.length - 1);
          mode = 'escaped';
        } else {
          mode = 'mu';
        }
        if (open > offset) {
          final token = _take('content', open, text: value);
          if (value.isNotEmpty) return token;
        }
        continue;
      }
      if (mode == 'escaped') {
        var end = offset + 2;
        while (end < source.length &&
            !source.startsWith('{{', end) &&
            !source.startsWith(r'\{{', end) &&
            !source.startsWith(r'\\{{', end)) {
          if (source.codeUnitAt(end) == 0) _hbFail('Invalid escaped content');
          end++;
        }
        if (end > source.length) _hbFail('Invalid escaped content');
        mode = 'initial';
        return _take('content', end);
      }
      if (mode == 'raw') {
        if (_at('{{{{') && !source.startsWith('/', offset + 4)) {
          rawDepth++;
          return _take('content', offset + 4);
        }
        if (_at('{{{{/')) {
          var end = offset + 5;
          while (end < source.length && _idUnit(end)) {
            end++;
          }
          if (end > offset + 5 && source.startsWith('}}}}', end)) {
            final name = source.substring(offset + 5, end);
            rawDepth--;
            if (rawDepth == 0) {
              mode = 'initial';
              return _take('rawEnd', end + 4, text: name);
            }
            return _take('content', end + 4);
          }
        }
        final next = source.indexOf('{{{{', offset + 1);
        final nul = source.indexOf('\u0000', offset);
        if (next < 0 || (nul >= 0 && nul < next)) _hbFail('Unclosed raw block');
        return _take('content', next);
      }

      // mu state. The order is the fixed lexer's rule order, not longest ID.
      if (_at('(')) return _take('sexprOpen', offset + 1);
      if (_at(')')) return _take('sexprClose', offset + 1);
      if (_at('{{{{')) return _take('rawOpen', offset + 4);
      if (_at('}}}}')) {
        mode = 'raw';
        rawDepth = 1;
        return _take('rawClose', offset + 4);
      }
      if (_at('{{')) {
        var p = offset + 2;
        if (p < source.length && source[p] == '~') p++;
        if (source.startsWith('#>', p)) return _take('partialBlock', p + 2);
        if (source.startsWith('>', p)) return _take('partial', p + 1);
        if (source.startsWith('#', p)) {
          p++;
          if (p < source.length && source[p] == '*') p++;
          return _take('block', p);
        }
        if (source.startsWith('/', p)) return _take('endBlock', p + 1);
        if (source.startsWith('^', p)) {
          var q = p + 1;
          while (_space(q)) {
            q++;
          }
          if (q < source.length && source[q] == '~') q++;
          if (source.startsWith('}}', q)) {
            mode = 'initial';
            return _take('inverse', q + 2);
          }
          return _take('inverted', p + 1);
        }
        var q = p;
        while (_space(q)) {
          q++;
        }
        final afterElse = q + 4;
        final elseBoundary = afterElse >= source.length || !RegExp(r'[A-Za-z0-9_]').hasMatch(source[afterElse]);
        if (source.startsWith('else', q) && elseBoundary) {
          var end = q + 4;
          while (_space(end)) {
            end++;
          }
          if (end < source.length && source[end] == '~') end++;
          if (source.startsWith('}}', end)) {
            mode = 'initial';
            return _take('inverse', end + 2);
          }
          return _take('inverseChain', q + 4);
        }
        if (source.startsWith('{', p)) return _take('unescaped', p + 1);
        if (source.startsWith('&', p)) return _take('open', p + 1);
        if (source.startsWith('!--', p)) {
          var end = source.indexOf('--', p + 3);
          while (end >= 0) {
            var close = end + 2;
            if (close < source.length && source[close] == '~') close++;
            if (source.startsWith('}}', close)) {
              mode = 'initial';
              return _take('comment', close + 2);
            }
            end = source.indexOf('--', end + 2);
          }
          _hbFail('Unclosed comment');
        }
        if (source.startsWith('!', p)) {
          final end = source.indexOf('}}', p + 1);
          if (end < 0) _hbFail('Unclosed comment');
          mode = 'initial';
          return _take('comment', end + 2);
        }
        if (source.startsWith('*', p)) p++;
        return _take('open', p);
      }
      if (_at('=')) return _take('equals', offset + 1);
      if (_at('..')) return _take('id', offset + 2);
      if (_at('.') && _look(offset + 1)) return _take('id', offset + 1);
      if (_at('.') || _at('/')) return _take('separator', offset + 1);
      if (_space(offset)) {
        var end = offset + 1;
        while (_space(end)) {
          end++;
        }
        _take('space', end);
        continue;
      }
      if (_at('}~}}') || _at('}}}')) {
        final end = offset + (_at('}~}}') ? 4 : 3);
        mode = 'initial';
        return _take('unescapedClose', end);
      }
      if (_at('~}}') || _at('}}')) {
        final end = offset + (_at('~}}') ? 3 : 2);
        mode = 'initial';
        return _take('close', end);
      }
      if (_at('"') || _at("'")) {
        final quote = source[offset];
        // Select the fixed lexer's whole match before stripping/unescaping:
        // its non-quote branch also accepts a backslash during backtracking.
        final pattern = quote == '"' ? RegExp(r'"(\\["]|[^"])*"') : RegExp(r"'(\\[']|[^'])*'");
        final match = pattern.matchAsPrefix(source, offset);
        if (match == null) _hbFail('Unclosed string');
        final value = match[0]!;
        return _take('string', match.end, text: value.substring(1, value.length - 1).replaceAll('\\$quote', quote));
      }
      if (_at('@')) return _take('data', offset + 1);
      for (final literal in const ['true', 'false', 'undefined', 'null']) {
        if (_at(literal) && _look(offset + literal.length, literal: true)) {
          return _take('literal', offset + literal.length);
        }
      }
      final number = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').matchAsPrefix(source, offset);
      if (number != null && _look(number.end, literal: true)) {
        return _take('number', number.end);
      }
      if (_at('as') && _space(offset + 2)) {
        var end = offset + 2;
        while (_space(end)) {
          end++;
        }
        if (source.startsWith('|', end)) return _take('paramsOpen', end + 1);
      }
      if (_at('|')) return _take('paramsClose', offset + 1);
      var end = offset;
      while (end < source.length && _idUnit(end)) {
        end++;
      }
      if (end > offset && _look(end)) return _take('id', end);
      if (_at('[')) {
        end = offset + 1;
        while (end < source.length) {
          if (source.startsWith(r'\]', end)) {
            end += 2;
          } else if (source[end] == ']') {
            final value = source.substring(offset, end + 1).replaceAllMapped(RegExp(r'\\([\\\]])'), (m) => m[1]!);
            return _take('id', end + 1, text: value);
          } else {
            end++;
          }
        }
        _hbFail('Unclosed bracket identifier');
      }
      _hbFail('Invalid template token');
    }
  }
}

sealed class _HbExpression {
  const _HbExpression(this.span);
  final _HbSpan span;
  Object? get original;
}

final class _HbLiteral extends _HbExpression {
  const _HbLiteral(this.value, super.span);
  final Object? value;
  @override
  Object? get original => value;
}

final class _HbPath extends _HbExpression {
  const _HbPath(this.name, this.parts, this.depth, this.data, super.span);
  final String name;
  final List<String> parts;
  final int depth;
  final bool data;
  bool get scoped => RegExp(r'^\.|this\b').hasMatch(name);
  bool get simple => parts.length == 1 && depth == 0 && !scoped;
  @override
  String get original => name;
}

final class _HbCall extends _HbExpression {
  const _HbCall(this.path, this.params, this.hash, super.span);
  final _HbExpression path;
  final List<_HbExpression> params;
  final List<(String, _HbExpression)> hash;
  @override
  Object? get original => _hbUndefined;
}

final class _HbStrip {
  const _HbStrip({this.open = false, this.close = false});
  final bool open, close;
  static _HbStrip tokens(String open, String close) =>
      _HbStrip(open: open.length > 2 && open[2] == '~', close: close.length >= 3 && close[close.length - 3] == '~');
}

final class _HbNode {
  _HbNode(
    this.kind,
    this.span, {
    this.call,
    String text = '',
    this.escaped = true,
    this.program,
    this.inverse,
    this.strip = const _HbStrip(),
    this.inverseStrip = const _HbStrip(),
    this.closeStrip = const _HbStrip(),
  }) : originalText = text,
       text = text;
  final String kind, originalText;
  final _HbSpan span;
  final _HbCall? call;
  final bool escaped;
  String text, indent = '';
  bool rightStripped = false, leftStripped = false;
  _HbProgram? program, inverse;
  _HbStrip strip, inverseStrip, closeStrip;
}

final class _HbProgram {
  _HbProgram(this.body, {this.chained = false});
  final List<_HbNode> body;
  List<String> blockParams = const [];
  bool chained;
}

final class _HbParser {
  _HbParser(String source) : lexer = _HbLexer(source);
  final _HbLexer lexer;
  final List<_HbToken> buffered = [];
  _HbToken _peek([int n = 0]) {
    while (buffered.length <= n) {
      buffered.add(lexer.next());
    }
    return buffered[n];
  }

  _HbToken _take([String? kind]) {
    final token = _peek();
    if (kind != null && token.kind != kind) _hbFail('Unexpected template token');
    buffered.removeAt(0);
    return token;
  }

  String _id(String value) => RegExp(r'^\[.*\]$').hasMatch(value) ? value.substring(1, value.length - 1) : value;

  _HbProgram parse() {
    final result = _program();
    _take('eof');
    return result;
  }

  _HbProgram _program() {
    final body = <_HbNode>[];
    while (!const {'eof', 'endBlock', 'inverse', 'inverseChain'}.contains(_peek().kind)) {
      body.add(_statement());
    }
    return _HbProgram(body);
  }

  _HbExpression _name() {
    final start = _take();
    if (start.kind == 'string') return _HbLiteral(start.text, start.span);
    if (start.kind == 'number') {
      return _HbLiteral(double.parse(start.text), start.span);
    }
    if (start.kind == 'literal') {
      return _HbLiteral(switch (start.text) {
        'true' => true,
        'false' => false,
        'null' => null,
        _ => _hbUndefined,
      }, start.span);
    }
    final data = start.kind == 'data';
    var token = data ? _take('id') : start;
    if (token.kind != 'id') _hbFail('Expected template path');
    final parts = <String>[];
    var depth = 0;
    var original = data ? '@' : '';
    var separator = '';
    while (true) {
      final part = _id(token.text);
      original = '$original$separator$part';
      if (part == token.text && const {'..', '.', 'this'}.contains(part)) {
        if (parts.isNotEmpty) _hbFail('Invalid template path');
        if (part == '..') depth++;
      } else {
        parts.add(part);
      }
      if (_peek().kind != 'separator') break;
      separator = _take().text;
      token = _take('id');
    }
    return _HbPath(original, parts, depth, data, start.span.through(token.span));
  }

  _HbExpression _param() {
    if (_peek().kind != 'sexprOpen') return _name();
    final open = _take();
    final call = _call(_name(), open.span, 'sexprClose');
    final close = _take('sexprClose');
    return _HbCall(call.path, call.params, call.hash, open.span.through(close.span));
  }

  _HbCall _call(_HbExpression path, _HbSpan start, String close, {bool blockParams = false}) {
    final params = <_HbExpression>[];
    final hash = <(String, _HbExpression)>[];
    while (_peek().kind != close && !(blockParams && _peek().kind == 'paramsOpen')) {
      if (_peek().kind == 'id' && _peek(1).kind == 'equals') {
        final key = _id(_take().text);
        _take('equals');
        hash.add((key, _param()));
      } else {
        if (hash.isNotEmpty) _hbFail('Positional parameter after hash');
        params.add(_param());
      }
    }
    return _HbCall(path, params, hash, start.through(_peek().span));
  }

  List<String> _blockParams() {
    if (_peek().kind != 'paramsOpen') return const [];
    _take();
    final names = <String>[_id(_take('id').text)];
    while (_peek().kind == 'id') {
      names.add(_id(_take().text));
    }
    _take('paramsClose');
    return names;
  }

  (_HbProgram, _HbStrip, bool) _inverse() {
    final open = _take();
    if (open.kind == 'inverse') {
      return (_program(), _HbStrip.tokens(open.text, open.text), false);
    }
    final call = _call(_name(), open.span, 'close', blockParams: true);
    final names = _blockParams();
    final close = _take('close');
    final strip = _HbStrip.tokens(open.text, close.text);
    final body = _program()..blockParams = names;
    final next = const {'inverse', 'inverseChain'}.contains(_peek().kind) ? _inverse() : null;
    final block = _HbNode(
      'block',
      call.span,
      call: call,
      program: body,
      inverse: next?.$1,
      strip: strip,
      inverseStrip: next?.$2 ?? const _HbStrip(),
      closeStrip: next?.$2 ?? const _HbStrip(),
    );
    if (next != null && next.$3) next.$1.body.first.closeStrip = block.closeStrip;
    return (_HbProgram([block], chained: true), strip, true);
  }

  _HbNode _statement() {
    final open = _take();
    if (open.kind == 'content') {
      return _HbNode('content', open.span, text: open.text);
    }
    if (open.kind == 'comment') {
      return _HbNode('comment', open.span, strip: _HbStrip.tokens(open.text, open.text));
    }
    if (open.kind == 'rawOpen') {
      final call = _call(_name(), open.span, 'rawClose');
      _take('rawClose');
      final content = <_HbNode>[];
      while (_peek().kind == 'content') {
        final text = _take();
        content.add(_HbNode('content', text.span, text: text.text));
      }
      final close = _take('rawEnd');
      if (call.path.original != close.text) _hbFail('Raw block name mismatch');
      return _HbNode('block', open.span.through(close.span), call: call, program: _HbProgram(content));
    }
    if (!const {'open', 'unescaped', 'block', 'inverted', 'partial', 'partialBlock'}.contains(open.kind)) {
      _hbFail('Unexpected statement');
    }
    final partial = open.kind == 'partial' || open.kind == 'partialBlock';
    final path = partial ? _param() : _name();
    final block = const {'block', 'inverted', 'partialBlock'}.contains(open.kind);
    final closeKind = open.kind == 'unescaped' ? 'unescapedClose' : 'close';
    final call = _call(path, open.span, closeKind, blockParams: block && !partial);
    final names = block && !partial ? _blockParams() : const <String>[];
    final openClose = _take(closeKind);
    final strip = _HbStrip.tokens(open.text, openClose.text);
    final decorator = open.text.contains('*');
    if (!block) {
      final flag = open.text.length > 3
          ? open.text[3]
          : open.text.length > 2
          ? open.text[2]
          : '';
      return _HbNode(
        partial
            ? 'partial'
            : decorator
            ? 'decorator'
            : 'mustache',
        open.span.through(openClose.span),
        call: call,
        strip: strip,
        escaped: flag != '{' && flag != '&',
      );
    }
    final body = _program()..blockParams = names;
    _HbProgram? inverse;
    var inverseStrip = const _HbStrip();
    var chain = false;
    if (const {'inverse', 'inverseChain'}.contains(_peek().kind)) {
      if (partial || decorator || (open.kind == 'inverted' && _peek().kind == 'inverseChain')) {
        _hbFail('Unexpected inverse');
      }
      final parsed = _inverse();
      inverse = parsed.$1;
      inverseStrip = parsed.$2;
      chain = parsed.$3;
    }
    final endOpen = _take('endBlock');
    final endName = _name();
    final endClose = _take('close');
    if (path.original != endName.original) _hbFail('Block name mismatch');
    final endStrip = _HbStrip.tokens(endOpen.text, endClose.text);
    if (chain) inverse!.body.first.closeStrip = endStrip;
    final result = _HbNode(
      partial
          ? 'partialBlock'
          : decorator
          ? 'decoratorBlock'
          : 'block',
      open.span.through(endClose.span),
      call: call,
      program: body,
      inverse: inverse,
      strip: strip,
      inverseStrip: inverseStrip,
      closeStrip: endStrip,
    );
    if (open.kind == 'inverted') {
      result.program = inverse;
      result.inverse = body;
    }
    return result;
  }
}

final class _HbWhitespace {
  bool rootSeen = false;
  void program(_HbProgram? program) {
    if (program == null) return;
    final root = !rootSeen;
    rootSeen = true;
    final body = program.body;
    for (var i = 0; i < body.length; i++) {
      final node = body[i];
      var strip = node.strip;
      var openStandalone = false, closeStandalone = false;
      final inline = node.kind == 'partial' || node.kind == 'comment';
      if (const {'block', 'decoratorBlock', 'partialBlock'}.contains(node.kind)) {
        this.program(node.program);
        this.program(node.inverse);
        final main = node.program ?? node.inverse!;
        final inverse = node.program == null ? null : node.inverse;
        var firstInverse = inverse, lastInverse = inverse;
        if (inverse != null && inverse.chained) {
          firstInverse = inverse.body.first.program;
          while (lastInverse!.chained) {
            lastInverse = lastInverse.body.last.program;
          }
        }
        strip = _HbStrip(open: node.strip.open, close: node.closeStrip.close);
        openStandalone = _next(main.body);
        closeStandalone = _previous((firstInverse ?? main).body);
        if (node.strip.close) _omitRight(main.body, multiple: true);
        if (inverse != null) {
          if (node.inverseStrip.open) _omitLeft(main.body, multiple: true);
          if (node.inverseStrip.close) _omitRight(firstInverse!.body, multiple: true);
          if (node.closeStrip.open) _omitLeft(lastInverse!.body, multiple: true);
          if (_previous(main.body) && _next(firstInverse!.body)) {
            _omitLeft(main.body);
            _omitRight(firstInverse.body);
          }
        } else if (node.closeStrip.open) {
          _omitLeft(main.body, multiple: true);
        }
      }
      if (node.kind == 'content') continue;
      final previous = _previous(body, i: i, root: root);
      final next = _next(body, i: i, root: root);
      if (strip.close) _omitRight(body, i: i, multiple: true);
      if (strip.open) _omitLeft(body, i: i, multiple: true);
      if (inline && previous && next) {
        _omitRight(body, i: i);
        if (_omitLeft(body, i: i) && node.kind == 'partial') {
          final indent = RegExp(r'[ \t]+$').firstMatch(body[i - 1].originalText);
          if (indent == null) _hbFail('Invalid standalone partial indentation');
          node.indent = indent[0]!;
        }
      }
      if (openStandalone && previous) {
        _omitRight((node.program ?? node.inverse!).body);
        _omitLeft(body, i: i);
      }
      if (closeStandalone && next) {
        _omitRight(body, i: i);
        _omitLeft((node.inverse ?? node.program!).body);
      }
    }
  }

  bool _previous(List<_HbNode> body, {int? i, bool root = false}) {
    final index = (i ?? body.length) - 1;
    if (index < 0) return root;
    if (body[index].kind != 'content') return false;
    final original = body[index].originalText;
    var end = original.length;
    while (end > 0 && isJsWhitespace(original.codeUnitAt(end - 1))) {
      end--;
    }
    return (index == 0 && root && end == 0) || original.substring(end).contains('\n');
  }

  bool _next(List<_HbNode> body, {int? i, bool root = false}) {
    final index = (i ?? -1) + 1;
    if (index >= body.length) return root;
    if (body[index].kind != 'content') return false;
    final original = body[index].originalText;
    var end = 0;
    while (end < original.length && isJsWhitespace(original.codeUnitAt(end))) {
      end++;
    }
    return original.substring(0, end).contains('\n') || (index == body.length - 1 && root && end == original.length);
  }

  void _omitRight(List<_HbNode> body, {int? i, bool multiple = false}) {
    final index = i == null ? 0 : i + 1;
    if (index >= body.length) return;
    final node = body[index];
    if (node.kind != 'content' || (!multiple && node.rightStripped)) return;
    final original = node.text;
    if (multiple) {
      var end = 0;
      while (end < original.length && isJsWhitespace(original.codeUnitAt(end))) {
        end++;
      }
      node.text = original.substring(end);
    } else {
      node.text = original.replaceFirst(RegExp(r'^[ \t]*\r?\n?'), '');
    }
    node.rightStripped = original != node.text;
  }

  bool _omitLeft(List<_HbNode> body, {int? i, bool multiple = false}) {
    final index = i == null ? body.length - 1 : i - 1;
    if (index < 0) return false;
    final node = body[index];
    if (node.kind != 'content' || (!multiple && node.leftStripped)) return false;
    final original = node.text;
    if (multiple) {
      var end = original.length;
      while (end > 0 && isJsWhitespace(original.codeUnitAt(end - 1))) {
        end--;
      }
      node.text = original.substring(0, end);
    } else {
      node.text = original.replaceFirst(RegExp(r'[ \t]+$'), '');
    }
    return node.leftStripped = original != node.text;
  }
}

final class _HbOpcode {
  const _HbOpcode(this.name, this.arguments, this.span);
  final Object? name;
  final List<Object?> arguments;
  final _HbSpan span;
}

final class _HbEnvironment {
  _HbEnvironment(_HbProgram program)
    : simple = program.body.length == 1,
      declaredBlockParams = program.blockParams.length;
  _HbEnvironment.raw();
  bool simple = false;
  Object? declaredBlockParams = 0;
  _HbRuntime? sourceRuntime;
  final List<_HbOpcode> opcodes = [];
  final List<_HbEnvironment> children = [];
  bool useDepths = false, useDecorators = false, usePartial = false;
  bool sharedDepths = false, sharedBlockParams = false;
  _HbCompiledProgram? compiled;
  void emit(String name, List<Object?> arguments, _HbSpan span) => opcodes.add(_HbOpcode(name, arguments, span));
  bool same(_HbEnvironment other) {
    if (opcodes.length != other.opcodes.length || children.length != other.children.length) return false;
    for (var i = 0; i < opcodes.length; i++) {
      if (opcodes[i].name != other.opcodes[i].name ||
          !_hbSameArguments(opcodes[i].arguments, other.opcodes[i].arguments)) {
        return false;
      }
    }
    for (var i = 0; i < children.length; i++) {
      if (!children[i].same(other.children[i])) return false;
    }
    return true;
  }
}

bool _hbSameArguments(Object? a, Object? b) {
  if (identical(a, b) || a == b) return true;
  if (a is List<Object?> && b is List<Object?> && a.length == b.length) {
    for (var i = 0; i < a.length; i++) {
      if (!_hbSameArguments(a[i], b[i])) return false;
    }
    return true;
  }
  return false;
}

final class _HbCompiler {
  static const known = {'helperMissing', 'blockHelperMissing', 'each', 'if', 'unless', 'with', 'log', 'lookup'};
  final List<_HbEnvironment?> environments = [];

  _HbCompiledProgram compile(_HbProgram program) => _generate(_environment(program, const []), -1);

  _HbPath _asPath(_HbExpression expression) => expression is _HbPath
      ? expression
      : _HbPath(
          ScriptCoercion.string(expression.original),
          [ScriptCoercion.string(expression.original)],
          0,
          false,
          expression.span,
        );
  (int, int)? _blockParam(String? name, List<List<String>> scopes) {
    if (name == null) return null;
    for (var i = 0; i < scopes.length; i++) {
      final index = scopes[i].indexOf(name);
      if (index >= 0) return (i, index);
    }
    return null;
  }

  String _classify(_HbCall call, _HbPath path, List<List<String>> scopes, {bool subexpression = false}) {
    final bound = path.simple && _blockParam(path.parts.first, scopes) != null;
    final helper = !bound && (subexpression || call.params.isNotEmpty || call.hash.isNotEmpty);
    if (helper || (!bound && path.simple && known.contains(path.parts.first))) return 'helper';
    return !bound && path.simple ? 'ambiguous' : 'simple';
  }

  _HbEnvironment _environment(_HbProgram program, List<List<String>> parents) {
    final result = _HbEnvironment(program);
    final scopes = [program.blockParams, ...parents];
    for (final node in program.body) {
      final span = node.span;
      if (node.kind == 'content') {
        if (node.text.isNotEmpty) result.emit('appendContent', [node.text], span);
        continue;
      }
      if (node.kind == 'comment') continue;
      final call = node.call!;
      int? child(_HbProgram? value) {
        if (value == null) return null;
        final next = _environment(value, scopes);
        final id = result.children.length;
        result.children.add(next);
        result.usePartial = result.usePartial || next.usePartial;
        result.useDepths = result.useDepths || next.useDepths;
        return id;
      }

      final main = child(node.program), inverse = child(node.inverse);
      if (node.kind == 'decorator' || node.kind == 'decoratorBlock') {
        _setup(result, call, main, null, scopes, span);
        result.useDecorators = true;
        result.emit('registerDecorator', [call.params.length, call.path.original], span);
      } else if (node.kind == 'partial' || node.kind == 'partialBlock') {
        result.usePartial = true;
        if (call.params.length > 1) _hbFail('Unsupported number of partial arguments');
        final dynamic = call.path is _HbCall;
        if (dynamic) _expression(result, call.path, scopes);
        final actual = call.params.isEmpty
            ? _HbCall(call.path, [_HbPath('', const [], 0, false, call.span)], call.hash, call.span)
            : call;
        _setup(result, actual, main, null, scopes, span, omitEmpty: true);
        result.emit('invokePartial', [dynamic, call.path.original, node.indent], span);
        result.emit('append', const [], span);
      } else {
        final path = _asPath(call.path);
        final type = _classify(call, path, scopes);
        _sexpr(result, call, path, type, main, inverse, scopes, span);
        if (node.kind == 'block') {
          if (type != 'helper') {
            result.emit('pushProgram', [main], span);
            result.emit('pushProgram', [inverse], span);
            result.emit('emptyHash', [false], span);
            result.emit(
              type == 'simple' ? 'blockValue' : 'ambiguousBlockValue',
              type == 'simple' ? [path.original] : const [],
              span,
            );
          }
          result.emit('append', const [], span);
        } else {
          result.emit(node.escaped ? 'appendEscaped' : 'append', const [], span);
        }
      }
    }
    return result;
  }

  void _setup(
    _HbEnvironment env,
    _HbCall call,
    int? main,
    int? inverse,
    List<List<String>> scopes,
    _HbSpan span, {
    bool omitEmpty = false,
  }) {
    for (final param in call.params) {
      _expression(env, param, scopes);
    }
    env.emit('pushProgram', [main], span);
    env.emit('pushProgram', [inverse], span);
    if (call.hash.isEmpty) {
      env.emit('emptyHash', [omitEmpty], span);
    } else {
      env.emit('pushHash', const [], span);
      for (final pair in call.hash) {
        _expression(env, pair.$2, scopes);
      }
      for (final pair in call.hash.reversed) {
        env.emit('assignToHash', [pair.$1], span);
      }
      env.emit('popHash', const [], span);
    }
  }

  void _sexpr(
    _HbEnvironment env,
    _HbCall call,
    _HbPath path,
    String type,
    int? main,
    int? inverse,
    List<List<String>> scopes,
    _HbSpan span,
  ) {
    if (type == 'simple') {
      _path(env, path, scopes, strict: true);
      env.emit('resolvePossibleLambda', const [], span);
    } else if (type == 'ambiguous') {
      env.emit('getContext', [path.depth], span);
      env.emit('pushProgram', [main], span);
      env.emit('pushProgram', [inverse], span);
      _path(env, path, scopes, strict: true);
      env.emit('invokeAmbiguous', [path.parts.first, main != null || inverse != null], span);
    } else {
      _setup(env, call, main, inverse, scopes, span);
      final name = path.parts.isEmpty ? null : path.parts.first;
      if (known.contains(name)) {
        env.emit('invokeKnownHelper', [call.params.length, name], span);
      } else {
        _path(env, path, scopes, strict: true, falsy: true);
        env.emit('invokeHelper', [call.params.length, path.original, path.simple], span);
      }
    }
  }

  void _expression(_HbEnvironment env, _HbExpression expression, List<List<String>> scopes) {
    if (expression is _HbLiteral) {
      env.emit(expression.value is String ? 'pushString' : 'pushLiteral', [expression.value], expression.span);
    } else if (expression is _HbPath) {
      _path(env, expression, scopes);
    } else if (expression is _HbCall) {
      final path = _asPath(expression.path);
      _sexpr(
        env,
        expression,
        path,
        _classify(expression, path, scopes, subexpression: true),
        null,
        null,
        scopes,
        expression.span,
      );
    }
  }

  void _path(_HbEnvironment env, _HbPath path, List<List<String>> scopes, {bool strict = false, bool falsy = false}) {
    if (path.depth != 0) env.useDepths = true;
    env.emit('getContext', [path.depth], path.span);
    final name = path.parts.isEmpty ? null : path.parts.first;
    final bound = path.depth == 0 && !path.scoped ? _blockParam(name, scopes) : null;
    if (bound != null) {
      env.emit('lookupBlockParam', [
        [bound.$1, bound.$2],
        path.parts,
      ], path.span);
    } else if (name == null || name.isEmpty) {
      env.emit('pushContext', const [], path.span);
    } else if (path.data) {
      env.emit('lookupData', [path.depth, path.parts, strict], path.span);
    } else {
      env.emit('lookupOnContext', [path.parts, falsy, strict, path.scoped], path.span);
    }
  }

  _HbCompiledProgram _generate(_HbEnvironment env, int index) {
    var depths = false, blockParams = false;
    for (final child in env.children) {
      _HbEnvironment? existing;
      for (final candidate in environments) {
        if (candidate != null && candidate.same(child)) {
          existing = candidate;
          break;
        }
      }
      if (existing == null) {
        final next = environments.length;
        environments.add(null);
        final compiled = _generate(child, next);
        depths = depths || compiled.useDepths;
        blockParams = blockParams || compiled.useBlockParams;
        child.sharedDepths = depths;
        child.sharedBlockParams = blockParams;
        environments[next] = child;
      } else {
        child.compiled = existing.compiled;
        depths = depths || existing.sharedDepths;
        blockParams = blockParams || existing.sharedBlockParams;
      }
    }
    depths = depths || env.useDepths || env.useDecorators;
    final builder = _HbPlanBuilder(env, index, depths, blockParams, environments);
    final compiled = builder.build();
    env.compiled = compiled;
    return compiled;
  }
}

typedef _HbEvaluate = Object? Function(_HbScope scope);

final class _HbEval {
  const _HbEval(
    this.evaluate, {
    this.absentProgram = false,
    this.literalUndefined = false,
    this.inline = true,
    this.literal = false,
    this.emptySource = false,
    this.invalidSyntax = false,
  });
  final _HbEvaluate evaluate;
  final bool absentProgram, literalUndefined, inline, literal, emptySource, invalidSyntax;
}

final class _HbScope {
  _HbScope(
    this.runtime,
    this.program,
    this.context,
    this.data,
    this.blockParams,
    this.depths, {
    this.decorator = false,
    Object? containerValue = _hbNotSupplied,
    Object? helpersValue = _hbNotSupplied,
    Object? partialsValue = _hbNotSupplied,
  }) : container = identical(containerValue, _hbNotSupplied) ? runtime.container : containerValue,
       helpers = identical(helpersValue, _hbNotSupplied) ? runtime.helpers : helpersValue,
       partials = identical(partialsValue, _hbNotSupplied) ? runtime.partials : partialsValue {
    if (!decorator && !program.lookupPropertyUsed) {
      lookupProperty = _hbUndefined;
      return;
    }
    final value = runtime.raw(container, 'lookupProperty');
    lookupProperty = runtime.truthy(value)
        ? value
        : runtime.function((_, args) {
            final parent = runtime._argument(args, 0), key = runtime._argument(args, 1);
            return runtime.owns(parent, runtime.propertyKey(key)) ? runtime.raw(parent, key) : _hbUndefined;
          }, 2);
  }
  final _HbRuntime runtime;
  final _HbCompiledProgram program;
  final Object? context, data, blockParams, depths;
  final Object? container, helpers, partials;
  late final Object? lookupProperty;
  final bool decorator;
  final Map<int, Object?> registers = {};
  Object? ambiguousOptions;
  Object? register(int index) => registers.containsKey(index) ? registers[index] : _hbUndefined;
  Object? atDepth(Object? depth) {
    if (depth == 0) return context;
    if (program.useDepths && runtime.truthy(depth)) return runtime.raw(depths, depth);
    _hbFail('Unbound generated context local');
  }

  Object? helperTable() {
    if (decorator) _hbFail('Unbound helpers in decorator function');
    return helpers;
  }

  Object? lookup(Object? parent, Object? key) => runtime.invoke(lookupProperty, _hbUndefined, [parent, key]);
  Object? containerCall(String name, List<Object?> args) => runtime.method(container, name, args);
  Object? callContext() {
    if (!_hbNullish(context)) return context;
    final fallback = runtime.raw(container, 'nullContext');
    return runtime.truthy(fallback) ? fallback : runtime.object();
  }
}

final class _HbInstruction {
  const _HbInstruction(this.expression, {this.statement = false, this.conditionalAppend = false});
  final _HbEval expression;
  final bool statement, conditionalAppend;
}

final class _HbCompiledProgram {
  _HbCompiledProgram(
    this.index,
    this.simple,
    this.declaredBlockParams,
    this.instructions,
    this.decorators,
    this.useDepths,
    this.useBlockParams,
    this.usePartial,
    this.useDecorators,
    this.lookupPropertyUsed,
  );
  final int index;
  final Object? declaredBlockParams;
  final bool simple, useDepths, useBlockParams;
  final bool usePartial, useDecorators;
  final bool lookupPropertyUsed;
  final Map<int, _HbCompiledProgram> children = {};
  final List<_HbInstruction> instructions;
  final List<_HbDecoratorPlan> decorators;
  late final _HbGeneratedCode generated;
}

// The fixed JavaScriptCompiler emits only these buffer/control statements
// around already-compiled template expressions. Keeping the source fragments
// separate retains repeated mergeSource effects without evaluating arbitrary
// JavaScript or turning an empty generated fragment into a fabricated value.
final class _HbSourceLine {
  _HbSourceLine(this.parts, {this.appendToBuffer = false});
  final List<Object> parts;
  final bool appendToBuffer;
  void prepend(String text) => parts.insert(0, text);
  void add(String text) => parts.add(text);
}

final class _HbGeneratedState {
  _HbGeneratedState(this.scope);
  final _HbScope scope;
  final Map<String, Object?> variables = {};
  bool returned = false;
  Object? result = _hbUndefined;
}

typedef _HbGeneratedStatement = void Function(_HbGeneratedState state);

final class _HbGeneratedExpression {
  const _HbGeneratedExpression(this.read, {this.variable});
  final Object? Function(_HbGeneratedState) read;
  final String? variable;
}

final class _HbGeneratedCode {
  _HbGeneratedCode(this.statements);
  final List<_HbGeneratedStatement> statements;
  Object? run(_HbScope scope) {
    final state = _HbGeneratedState(scope);
    for (final statement in statements) {
      statement(state);
      if (state.returned) break;
    }
    return state.result;
  }
}

final class _HbGeneratedParser {
  _HbGeneratedParser(List<_HbSourceLine> source) {
    for (final line in source) {
      for (final part in line.parts) {
        if (part is _HbEval) {
          if (part.invalidSyntax) _hbFail('Invalid generated expression syntax');
          if (!part.emptySource) tokens.add(part);
          continue;
        }
        final text = part as String;
        var i = 0;
        while (i < text.length) {
          if (isJsWhitespace(text.codeUnitAt(i))) {
            i++;
            continue;
          }
          if (text.startsWith('""', i) || text.startsWith("''", i)) {
            tokens.add(_HbEval((_) => '', literal: true));
            i += 2;
            continue;
          }
          final word = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(text.substring(i));
          if (word != null) {
            tokens.add(word[0]!);
            i += word[0]!.length;
            continue;
          }
          if (text.startsWith('+=', i) || text.startsWith('!=', i)) {
            tokens.add(text.substring(i, i + 2));
            i += 2;
            continue;
          }
          if (';=+(),{}'.contains(text[i])) {
            tokens.add(text[i++]);
            continue;
          }
          _hbFail('Invalid fixed generated source token');
        }
      }
    }
  }
  final List<Object> tokens = [];
  int cursor = 0;
  Object? get _next => cursor < tokens.length ? tokens[cursor] : null;
  bool _take(String token) {
    if (_next != token) return false;
    cursor++;
    return true;
  }

  void _require(String token) {
    if (!_take(token)) _hbFail('Invalid fixed generated source syntax');
  }

  String _identifier() {
    final token = _next;
    if (token is! String ||
        !RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(token) ||
        const {'return', 'var', 'if', 'else', 'null', 'true', 'false'}.contains(token)) {
      _hbFail('Invalid generated variable');
    }
    cursor++;
    return token;
  }

  _HbGeneratedCode parse() {
    final result = <_HbGeneratedStatement>[];
    while (_next != null) {
      result.add(_statement());
    }
    return _HbGeneratedCode(result);
  }

  _HbGeneratedStatement _statement() {
    if (_take(';')) return (_) {};
    if (_take('{')) {
      final statements = <_HbGeneratedStatement>[];
      while (_next != '}' && _next != null) {
        statements.add(_statement());
      }
      _require('}');
      return (state) {
        for (final statement in statements) {
          statement(state);
          if (state.returned) break;
        }
      };
    }
    if (_take('if')) {
      _require('(');
      final condition = _assignment();
      _require(')');
      final yes = _statement(), no = _take('else') ? _statement() : null;
      return (state) {
        if (state.scope.runtime.truthy(condition.read(state))) {
          yes(state);
        } else {
          no?.call(state);
        }
      };
    }
    if (_take('return')) {
      final value = _next == ';' || _next == null || _next == '}' ? null : _assignment();
      _semicolon();
      return (state) {
        state.result = value == null ? _hbUndefined : value.read(state);
        state.returned = true;
      };
    }
    if (_take('var')) {
      final entries = <(String, _HbGeneratedExpression?)>[];
      do {
        final name = _identifier();
        entries.add((name, _take('=') ? _assignment() : null));
      } while (_take(','));
      _semicolon();
      return (state) {
        for (final entry in entries) {
          if (entry.$2 != null) state.variables[entry.$1] = entry.$2!.read(state);
        }
      };
    }
    final value = _assignment();
    _semicolon();
    return (state) {
      value.read(state);
    };
  }

  void _semicolon() {
    if (!_take(';') && _next != null && _next != '}') _hbFail('Missing generated statement separator');
  }

  _HbGeneratedExpression _assignment() {
    final left = _equality();
    if (_next != '=' && _next != '+=') return left;
    final operation = tokens[cursor++] as String;
    final name = left.variable;
    if (name == null) _hbFail('Invalid generated assignment target');
    final right = _assignment();
    return _HbGeneratedExpression((state) {
      final prior = operation == '+=' ? left.read(state) : _hbUndefined;
      final value = right.read(state);
      return state.variables[name] = operation == '+=' ? state.scope.runtime.add(prior, value) : value;
    });
  }

  _HbGeneratedExpression _equality() {
    var result = _addition();
    while (_take('!=')) {
      final left = result, right = _addition();
      result = _HbGeneratedExpression((state) => !state.scope.runtime.equal(left.read(state), right.read(state)));
    }
    return result;
  }

  _HbGeneratedExpression _addition() {
    var result = _atom();
    while (_take('+')) {
      final left = result, right = _atom();
      result = _HbGeneratedExpression((state) => state.scope.runtime.add(left.read(state), right.read(state)));
    }
    return result;
  }

  _HbGeneratedExpression _atom() {
    final value = _next;
    if (value is _HbEval) {
      cursor++;
      return _HbGeneratedExpression((state) => value.evaluate(state.scope));
    }
    if (_take('(')) {
      final result = _assignment();
      _require(')');
      return result;
    }
    if (_take('null')) return const _HbGeneratedExpression(_nullValue);
    final name = _identifier();
    return _HbGeneratedExpression(
      (state) => state.variables.containsKey(name) ? state.variables[name] : _hbUndefined,
      variable: name,
    );
  }

  static Object? _nullValue(_HbGeneratedState _) => null;
}

final class _HbOptionsPlan {
  _HbOptionsPlan(
    this.name,
    this.params,
    this.hash,
    this.main,
    this.inverse,
    this.span,
    this.blockParams, {
    this.serializeLocation = true,
  }) : location = span.sourceRuntime == null || !serializeLocation
           ? _hbUndefined
           : _hbJsonProjection(span.sourceRuntime!, span.sourceLocation);
  final Object? name;
  final List<_HbEval> params;
  final _HbEval hash, main, inverse;
  final _HbSpan span;
  final bool blockParams;
  final Object? location;
  bool invalidSyntax({bool objectArguments = false}) =>
      hash.invalidSyntax ||
      hash.emptySource ||
      (!main.absentProgram && (main.invalidSyntax || main.emptySource)) ||
      (!inverse.absentProgram && (inverse.invalidSyntax || inverse.emptySource)) ||
      params.any((value) => value.invalidSyntax || (!objectArguments && value.emptySource && !value.literal)) ||
      (span.sourceRuntime != null && serializeLocation && ScriptCoercion.isUndefined(location));
  final bool serializeLocation;
  _HbObject options(
    _HbScope scope, {
    bool objectArguments = false,
    bool includeName = true,
    bool includeLocation = true,
  }) {
    final rt = scope.runtime;
    final result = rt.object();
    if (includeName) result.define('name', ScriptCoercion.string(name));
    if (!hash.literalUndefined) result.define('hash', hash.evaluate(scope));
    if (!main.absentProgram || !inverse.absentProgram) {
      result.define('fn', main.absentProgram ? rt.raw(scope.container, 'noop') : main.evaluate(scope));
      result.define('inverse', inverse.absentProgram ? rt.raw(scope.container, 'noop') : inverse.evaluate(scope));
    }
    if (objectArguments) {
      final args = rt.array([]);
      for (var i = 0; i < params.length; i++) {
        final param = params[i];
        if (param.emptySource && !param.literal) {
          if (i + 1 < params.length) rt.set(args, 'length', i + 1);
        } else {
          rt.set(args, '$i', param.evaluate(scope));
        }
      }
      result.define('args', args);
    }
    result.define('data', scope.data);
    if (blockParams) result.define('blockParams', scope.blockParams);
    if (includeLocation && span.sourceRuntime == null) {
      result.define(
        'loc',
        rt.object({
          'start': rt.object({'line': span.line, 'column': span.column}),
          'end': rt.object({'line': span.endLine, 'column': span.endColumn}),
        }),
      );
    } else if (includeLocation && !ScriptCoercion.isUndefined(location)) {
      result.define('loc', _hbLoadJson(rt, location));
    }
    return result;
  }
}

final class _HbDecoratorPlan {
  const _HbDecoratorPlan(this.name, this.options);
  final Object? name;
  final _HbOptionsPlan options;
}

final class _HbPlanBuilder {
  _HbPlanBuilder(this.env, this.index, this.useDepths, this.useBlockParams, this.environments);
  final _HbEnvironment env;
  final List<_HbEnvironment?> environments;
  final int index;
  final bool useDepths;
  bool useBlockParams;
  Object? context = 0;
  int nextRegister = 0;
  String? lastHelper;
  bool lookupPropertyUsed = false;
  int reservedStackSlots = 0;
  bool invalidRegister = false;
  bool invalidGeneratedSource = false;
  bool hasStackVariables = false;
  final List<_HbEval> stack = [];
  final List<Map<String, _HbEval>> hashes = [];
  final List<_HbInstruction> instructions = [];
  final List<_HbSourceLine> source = [];
  final List<_HbDecoratorPlan> decorators = [];
  Object? pendingContent = '';
  _HbSpan? pendingSpan;

  _HbEval _constant(Object? value, {bool absentProgram = false}) => _HbEval(
    (_) => value,
    absentProgram: absentProgram,
    literalUndefined: ScriptCoercion.isUndefined(value),
    literal: true,
  );
  Object? _lookupKey(Object? value) => env.sourceRuntime == null ? value : _hbJsonProjection(env.sourceRuntime!, value);
  _HbEval _pop() {
    if (stack.isEmpty) {
      if (reservedStackSlots == 0) _hbFail('Invalid compiler stack');
      reservedStackSlots--;
      return _HbEval((_) => _hbUndefined, emptySource: true);
    }
    return stack.removeLast();
  }

  void _addInstruction(_HbInstruction instruction) {
    instructions.add(instruction);
    final value = instruction.expression;
    if (instruction.statement) {
      source.add(_HbSourceLine([value, ';']));
    } else if (instruction.conditionalAppend) {
      source.add(
        _HbSourceLine([
          'if (',
          value,
          ' != null) { ',
          env.simple ? 'return ' : 'buffer += ',
          value,
          '; }',
          if (env.simple) ' else { return ""; }',
        ]),
      );
    } else if (env.simple) {
      source.add(_HbSourceLine(['return ', value, ';']));
    } else {
      source.add(_HbSourceLine([value], appendToBuffer: true));
    }
  }

  void _mergeSource({required bool functionContext}) {
    var appendOnly = true, appendFirst = false, seen = false;
    _HbSourceLine? start, end;
    for (final line in List<_HbSourceLine>.of(source)) {
      if (line.appendToBuffer) {
        if (start != null) {
          line.prepend('  + ');
        } else {
          start = line;
        }
        end = line;
      } else {
        if (start != null) {
          if (!seen) {
            appendFirst = true;
          } else {
            start.prepend('buffer += ');
          }
          end!.add(';');
          start = end = null;
        }
        seen = true;
        if (!env.simple) appendOnly = false;
      }
    }
    String? declarations = functionContext
        ? hasStackVariables || nextRegister > 0 || lookupPropertyUsed
              ? ', locals'
              : ''
        : null;
    if (appendOnly) {
      if (start != null) {
        start.prepend('return ');
        end!.add(';');
      } else if (!seen) {
        source.add(_HbSourceLine(['return "";']));
      }
    } else {
      declarations = '${declarations ?? 'undefined'}, buffer = ${appendFirst ? '' : '""'}';
      if (start != null) {
        start.prepend('return buffer + ');
        end!.add(';');
      } else {
        source.add(_HbSourceLine(['return buffer;']));
      }
    }
    if (declarations != null && declarations.isNotEmpty) {
      source.insert(0, _HbSourceLine(['var ${declarations.substring(2)}${appendFirst ? '' : ';\n'}']));
    }
  }

  void _flushInline() {
    for (var i = 0; i < stack.length; i++) {
      final value = stack[i];
      if (!value.inline) continue;
      if (value.literal) {
        stack[i] = _HbEval(
          value.evaluate,
          absentProgram: value.absentProgram,
          literalUndefined: value.literalUndefined,
          inline: false,
          literal: true,
          emptySource: value.emptySource,
          invalidSyntax: value.invalidSyntax,
        );
      } else {
        _flushContent();
        if (value.emptySource || value.invalidSyntax) invalidGeneratedSource = true;
        hasStackVariables = true;
        final register = nextRegister++;
        _addInstruction(
          _HbInstruction(
            _HbEval((scope) {
              scope.registers[register] = value.evaluate(scope);
              return _hbUndefined;
            }),
            statement: true,
          ),
        );
        stack[i] = _HbEval((scope) => scope.register(register), inline: false);
      }
    }
  }

  void _flushContent() {
    final rt = env.sourceRuntime;
    if (rt == null ? pendingContent != '' : rt.truthy(pendingContent)) {
      final content = rt == null ? pendingContent : rt.add(pendingContent, '');
      if (pendingSpan != null) _hbCheckSourceLocation(pendingSpan!);
      _addInstruction(_HbInstruction(_constant(content)));
      pendingContent = '';
    }
  }

  _HbOptionsPlan _options(Object? name, Object? count, _HbSpan span, {bool serializeLocation = true}) {
    final actualName = env.sourceRuntime?.add(name, '') ?? ScriptCoercion.string(name);
    final hash = _pop(), inverse = _pop(), main = _pop();
    final params = <_HbEval>[];
    var remaining = env.sourceRuntime?.number(count) ?? (count! as num).toDouble();
    while (remaining != 0 && !remaining.isNaN) {
      remaining--;
      params.insert(0, _pop());
    }
    final result = _HbOptionsPlan(
      actualName,
      params,
      hash,
      main,
      inverse,
      span,
      useBlockParams,
      serializeLocation: serializeLocation,
    );
    if (serializeLocation) _hbCheckSourceLocation(span);
    return result;
  }

  _HbEval _resolve(_HbEval base, List<String> parts, int start, bool falsy) => _HbEval((scope) {
    var current = base.evaluate(scope);
    for (var i = start; i < parts.length; i++) {
      if (falsy ? !scope.runtime.truthy(current) : _hbNullish(current)) return current;
      current = scope.lookup(current, parts[i]);
    }
    return current;
  }, invalidSyntax: base.invalidSyntax);

  _HbCompiledProgram build() {
    for (final opcode in env.opcodes) {
      final args = [...opcode.arguments];
      while (args.length < 4) {
        args.add(_hbUndefined);
      }
      final name = opcode.name is String ? opcode.name! as String : env.sourceRuntime!.propertyKey(opcode.name);
      switch (name) {
        case 'getContext':
          context = args[0];
        case 'pushContext':
          final depth = context;
          stack.add(_HbEval((s) => s.atDepth(depth), literal: true));
        case 'pushString':
          stack.add(_constant(env.sourceRuntime?.add(args[0], '') ?? args[0]));
        case 'pushLiteral':
          if (opcode.arguments.isEmpty) {
            stack.add(_HbEval((_) => _hbUndefined, literal: true, emptySource: true, absentProgram: true));
          } else {
            final value = args[0];
            stack.add(_constant(value, absentProgram: value == null || value == false || value == 0));
          }
        case 'lookupOnContext':
          _hbCheckSourceLocation(opcode.span);
          final depth = context;
          final parts = args[0];
          if (parts is! List<String>) _hbFail('Invalid generated context path');
          lookupPropertyUsed = lookupPropertyUsed || parts.isNotEmpty;
          stack.add(_resolve(_HbEval((s) => s.atDepth(depth)), parts, 0, args[1]! as bool));
        case 'lookupData':
          _hbCheckSourceLocation(opcode.span);
          final rawDepth = args[0], parts = args[1];
          if (rawDepth is! num || parts is! List<String>) _hbFail('Invalid generated data path');
          lookupPropertyUsed = lookupPropertyUsed || parts.isNotEmpty;
          final depth = rawDepth.toInt();
          final base = _HbEval((s) {
            return depth == 0 ? s.data : s.containerCall('data', [s.data, depth]);
          });
          stack.add(_resolve(base, parts, 0, true));
        case 'lookupBlockParam':
          _hbCheckSourceLocation(opcode.span);
          useBlockParams = true;
          final address = args[0], parts = args[1];
          if (address is! List<int> || parts is! List<String>) _hbFail('Invalid block parameter address');
          lookupPropertyUsed = lookupPropertyUsed || parts.length > 1;
          stack.add(
            _resolve(
              _HbEval((s) => s.runtime.raw(s.runtime.raw(s.blockParams, '${address[0]}'), '${address[1]}')),
              parts,
              1,
              false,
            ),
          );
        case 'resolvePossibleLambda':
          _hbCheckSourceLocation(opcode.span);
          final value = _pop();
          stack.add(
            _HbEval((s) {
              final lambda = s.runtime.raw(s.container, 'lambda');
              final current = value.evaluate(s);
              return s.runtime.invoke(lambda, s.container, [current, s.context]);
            }, invalidSyntax: value.invalidSyntax || value.emptySource),
          );
        case 'pushProgram':
          final guid = args[0];
          if (_hbNullish(guid)) {
            stack.add(_constant(null, absentProgram: true));
          } else {
            final key = env.sourceRuntime?.propertyKey(guid) ?? ScriptCoercion.string(guid);
            final childIndex = ScriptCoercion.arrayIndex(key);
            if (childIndex == null || childIndex >= env.children.length) {
              _hbFail('Undefined compiled child program');
            }
            final child = env.children[childIndex];
            final passBlocks = useBlockParams || useDepths;
            final declared = child.sourceRuntime == null
                ? child.declaredBlockParams
                : _hbProgramArgument(child.sourceRuntime!, child.declaredBlockParams, followedByArgument: passBlocks);
            stack.add(
              _HbEval(
                (s) => s.containerCall('program', [
                  child.compiled!.index,
                  s.data,
                  declared,
                  if (passBlocks) s.blockParams,
                  if (useDepths) s.depths,
                ]),
                literal: true,
              ),
            );
          }
        case 'emptyHash':
          stack.add(args[0] == true ? _constant(_hbUndefined) : _HbEval((s) => s.runtime.object(), literal: true));
        case 'pushHash':
          hashes.add({});
        case 'assignToHash':
          final value = _pop(), key = env.sourceRuntime?.propertyKey(args[0]) ?? args[0]! as String;
          if (hashes.isEmpty) _hbFail('No active compiler hash');
          if (key != '__proto__') hashes.last[key] = value;
        case 'popHash':
          _hbCheckSourceLocation(opcode.span);
          if (hashes.isEmpty) _hbFail('No active compiler hash');
          final values = hashes.removeLast();
          final numeric = <(int, String)>[], ordinary = <String>[];
          for (final key in values.keys) {
            final index = ScriptCoercion.arrayIndex(key);
            if (index == null) {
              ordinary.add(key);
            } else {
              numeric.add((index, key));
            }
          }
          numeric.sort((a, b) => a.$1.compareTo(b.$1));
          final keys = [...numeric.map((e) => e.$2), ...ordinary];
          stack.add(
            _HbEval(
              (s) {
                final result = s.runtime.object();
                for (final key in keys) {
                  final value = values[key]!;
                  if (!value.literalUndefined) result.define(key, value.evaluate(s));
                }
                return result;
              },
              invalidSyntax: values.values.any(
                (value) => !value.literalUndefined && (value.invalidSyntax || value.emptySource),
              ),
            ),
          );
        case 'invokeKnownHelper':
        case 'invokeHelper':
          final unknown = name == 'invokeHelper';
          final nonHelper = unknown ? _pop() : null;
          final helperName = args[1], simple = !unknown || args[2] == true;
          // setupHelper constructs its name lookup even when the emitted
          // invocation ultimately selects only the non-helper expression.
          lookupPropertyUsed = true;
          final plan = _options(helperName, args[0], opcode.span);
          final key = _lookupKey(helperName);
          stack.add(
            _HbEval(
              (s) {
                final rt = s.runtime;
                Object? callee = _hbUndefined;
                if (simple) callee = s.lookup(s.helperTable(), _hbLoadJson(rt, key));
                if (unknown) {
                  if (!rt.truthy(callee)) callee = nonHelper!.evaluate(s);
                  if (!rt.truthy(callee)) callee = rt.raw(rt.raw(s.container, 'hooks'), 'helperMissing');
                }
                final call = rt.raw(callee, 'call');
                final receiver = s.callContext();
                final values = [receiver, for (final p in plan.params) p.evaluate(s), plan.options(s)];
                return rt.invoke(call, callee, values);
              },
              invalidSyntax: plan.invalidSyntax() || nonHelper?.invalidSyntax == true || nonHelper?.emptySource == true,
            ),
          );
        case 'invokeAmbiguous':
          lookupPropertyUsed = true;
          final nonHelper = _pop(),
              name = env.sourceRuntime?.add(args[0], '') ?? ScriptCoercion.string(args[0]),
              block = args[1] == true;
          stack.add(_HbEval((s) => s.runtime.object()));
          final plan = _options(name, 0, opcode.span);
          lastHelper = name as String;
          stack.add(
            _HbEval((s) {
              final rt = s.runtime;
              var helper = s.lookup(s.helperTable(), name);
              if (!rt.truthy(helper)) helper = nonHelper.evaluate(s);
              if (_hbNullish(helper)) helper = rt.raw(rt.raw(s.container, 'hooks'), 'helperMissing');
              _HbObject? options;
              if (block) {
                options = plan.options(s);
                s.ambiguousOptions = options;
              }
              if (helper is! _HbFunction) return helper;
              final call = rt.raw(helper, 'call');
              final receiver = s.callContext();
              return rt.invoke(call, helper, [receiver, options ?? plan.options(s)]);
            }, invalidSyntax: plan.invalidSyntax() || nonHelper.invalidSyntax || nonHelper.emptySource),
          );
        case 'blockValue':
          final plan = _options(args[0], 0, opcode.span), value = _pop();
          stack.add(
            _HbEval((s) {
              final rt = s.runtime, callee = s.runtime.raw(s.runtime.raw(s.container, 'hooks'), 'blockHelperMissing');
              final call = rt.raw(callee, 'call');
              return rt.invoke(call, callee, [s.context, value.evaluate(s), plan.options(s)]);
            }, invalidSyntax: plan.invalidSyntax() || value.invalidSyntax || (value.emptySource && !value.literal)),
          );
        case 'ambiguousBlockValue':
          _options('', 0, opcode.span); // Duplicate option expressions are not emitted.
          final value = _pop(), name = lastHelper!, register = nextRegister++;
          _flushContent();
          _addInstruction(
            _HbInstruction(
              _HbEval((s) {
                final rt = s.runtime;
                var result = value.evaluate(s);
                if (!rt.truthy(s.lookup(s.helperTable(), name))) {
                  result = rt.method(rt.raw(rt.raw(s.container, 'hooks'), 'blockHelperMissing'), 'call', [
                    s.context,
                    result,
                    s.ambiguousOptions,
                  ]);
                }
                s.registers[register] = result;
                return _hbUndefined;
              }, invalidSyntax: value.invalidSyntax || value.emptySource),
              statement: true,
            ),
          );
          stack.add(_HbEval((s) => s.register(register), inline: false));
        case 'registerDecorator':
          lookupPropertyUsed = true;
          final key = _lookupKey(args[1]);
          final plan = _options(args[1], args[0], opcode.span);
          final rt = env.sourceRuntime;
          if (rt != null) rt.add(rt.add('Missing decorator: "', args[1]), '"');
          decorators.add(_HbDecoratorPlan(key, plan));
        case 'invokePartial':
          final dynamic = args[0] == true, name = args[1];
          if (!dynamic) lookupPropertyUsed = true;
          final plan = _options(name, 1, opcode.span, serializeLocation: false);
          final rt = env.sourceRuntime;
          final indent = rt == null
              ? args[2]
              : rt.truthy(args[2])
              ? _hbJsonProjection(rt, args[2])
              : '';
          final key = dynamic ? null : _lookupKey(name);
          _hbCheckSourceLocation(opcode.span);
          final dynamicName = dynamic ? _pop() : null;
          stack.add(
            _HbEval(
              (s) {
                final rt = s.runtime;
                final invokePartial = rt.raw(s.container, 'invokePartial');
                if (s.decorator) _hbFail('Unbound partials in decorator function');
                final partial = dynamic ? dynamicName!.evaluate(s) : s.lookup(s.partials, _hbLoadJson(rt, key));
                final context = plan.params.single.evaluate(s);
                final options = plan.options(s, includeName: !dynamic, includeLocation: false);
                if (!ScriptCoercion.isUndefined(indent) && rt.truthy(indent)) {
                  options.define('indent', _hbLoadJson(rt, indent));
                }
                options.define('helpers', s.helperTable());
                options.define('partials', s.partials);
                options.define('decorators', rt.raw(s.container, 'decorators'));
                return rt.invoke(invokePartial, s.container, [partial, context, options]);
              },
              invalidSyntax:
                  plan.invalidSyntax() ||
                  dynamicName?.invalidSyntax == true ||
                  (dynamicName?.emptySource == true && dynamicName?.literal != true),
            ),
          );
        case 'appendContent':
          final rt = env.sourceRuntime;
          if (rt == null ? pendingContent == '' : !rt.truthy(pendingContent)) {
            pendingSpan = opcode.span;
          }
          pendingContent = rt == null
              ? '$pendingContent${args[0]}'
              : rt.truthy(pendingContent)
              ? rt.add(pendingContent, args[0])
              : args[0];
        case 'append':
        case 'appendEscaped':
          final value = _pop(), escaped = name == 'appendEscaped';
          _flushContent();
          _hbCheckSourceLocation(opcode.span);
          if (!escaped && value.emptySource) invalidGeneratedSource = true;
          _addInstruction(
            _HbInstruction(
              _HbEval((s) {
                final escape = escaped ? s.runtime.raw(s.container, 'escapeExpression') : _hbUndefined;
                final result = value.evaluate(s);
                return escaped
                    ? s.runtime.invoke(escape, s.container, [result])
                    : value.inline && _hbNullish(result)
                    ? ''
                    : result;
              }, invalidSyntax: value.invalidSyntax),
              conditionalAppend: !escaped && !value.inline,
            ),
          );
        default:
          if (env.sourceRuntime != null) {
            final rt = env.sourceRuntime!;
            // A Compiler.opcode AST dispatch supplies the node as the opcode
            // property key and an empty argument array. These branches model
            // those actual no-argument calls; they are not alternate opcodes
            // exposed by the public template language.
            switch (name) {
              case 'nameLookup':
              case 'internalNameLookup':
                lookupPropertyUsed = true;
                continue;
              case 'compilerInfo':
              case 'initializeBuffer':
              case 'lookupPropertyFunctionVarDeclaration':
              case 'contextName':
              case 'quotedString':
              case 'topStackName':
              case 'isInline':
              case 'topStack':
              case 'compiler':
                continue;
              case 'depthedLookup':
              case 'aliasable':
              case 'appendToBuffer':
                _hbCheckSourceLocation(opcode.span);
                continue;
              case 'compile':
              case 'compileChildren':
              case 'resolvePath':
              case 'itemsSeparatedBy':
              case 'programExpression':
              case 'objectLiteral':
                _hbFail('Undefined required compiler argument');
              case 'matchExistingProgram':
                if (environments.any((candidate) => candidate != null)) {
                  _hbFail('Undefined program comparison argument');
                }
                continue;
              case 'preamble':
                context = 0;
                instructions.clear();
                source.clear();
                invalidGeneratedSource = false;
                decorators.clear();
                continue;
              case 'pushSource':
                _flushContent();
                continue;
              case 'popStack':
                _pop();
                continue;
              case 'incrStack':
                reservedStackSlots++;
                hasStackVariables = true;
                continue;
              case 'useRegister':
                invalidRegister = true;
                continue;
              case 'push':
                _hbCheckSourceLocation(opcode.span);
                stack.add(_HbEval((_) => _hbUndefined, emptySource: true));
                continue;
              case 'pushStackLiteral':
                stack.add(_HbEval((_) => _hbUndefined, literal: true, emptySource: true, absentProgram: true));
                continue;
              case 'pushId':
                stack.add(_constant(null));
                continue;
              case 'pushStringParam':
                final depth = context;
                stack.add(_HbEval((s) => s.atDepth(depth), literal: true));
                stack.add(_constant('undefined'));
                stack.add(_HbEval((_) => _hbUndefined, literal: true, emptySource: true, absentProgram: true));
                continue;
              case 'replaceStack':
                if (stack.isEmpty || !stack.last.inline) _hbFail('replaceStack on non-inline');
                _pop();
                _hbFail('Undefined compiler replacement callback');
              case 'flushInline':
                _flushInline();
                continue;
              case 'setupParams':
                _options(_hbUndefined, _hbUndefined, opcode.span, serializeLocation: false);
                _hbCheckSourceLocation(opcode.span);
                continue;
              case 'setupHelperArgs':
                _options(_hbUndefined, _hbUndefined, opcode.span);
                continue;
              case 'setupHelper':
                _options(_hbUndefined, _hbUndefined, opcode.span);
                lookupPropertyUsed = true;
                continue;
              case 'createFunctionContext':
              case 'mergeSource':
                _mergeSource(functionContext: name == 'createFunctionContext');
                _hbCheckSourceLocation(opcode.span);
                continue;
            }
            final inherited = rt.raw(rt.object(), name);
            if (inherited is _HbFunction) {
              rt.invoke(inherited, rt.object(), []);
            } else {
              _hbFail('Unknown generated compiler opcode');
            }
          } else {
            throw StateError('Unknown internal Handlebars opcode');
          }
      }
    }
    _flushContent();
    if (stack.isNotEmpty || reservedStackSlots != 0) _hbFail('Incomplete compiler stack');
    if (invalidRegister) _hbFail('Empty generated register declaration');
    if (invalidGeneratedSource) _hbFail('Empty generated expression');
    if (decorators.any((plan) => plan.options.invalidSyntax(objectArguments: true))) {
      _hbFail('Invalid generated decorator expression');
    }
    _mergeSource(functionContext: true);
    final generated = _HbGeneratedParser(source).parse();
    final result = _HbCompiledProgram(
      index,
      env.simple,
      env.declaredBlockParams,
      instructions,
      decorators,
      useDepths,
      useBlockParams,
      env.usePartial,
      decorators.isNotEmpty || env.children.any((child) => child.compiled!.useDecorators),
      lookupPropertyUsed,
    );
    result.generated = generated;
    for (final child in env.children) {
      final compiled = child.compiled!;
      result.children[compiled.index] = compiled;
      result.children.addAll(compiled.children);
    }
    return result;
  }
}

typedef _HbBody = Object? Function(Object? receiver, List<Object?> arguments);
typedef _HbGetter = Object? Function(Object? receiver);

final class _HbOwn {
  _HbOwn(this.value, {this.enumerable = true, this.getter});
  Object? value;
  final bool enumerable;
  final _HbGetter? getter;
  _HbFunction? getterFunction;
  _HbFunction? setterFunction;
}

class _HbObject {
  _HbObject(this.prototype);
  _HbObject? prototype;
  bool sealed = false;
  final Map<String, _HbOwn> own = {};
  void define(String key, Object? value, {bool enumerable = true, _HbGetter? getter}) {
    own[key] = _HbOwn(value, enumerable: enumerable, getter: getter);
  }
}

final class _HbFunction extends _HbObject {
  _HbFunction(super.prototype, this.body, this.arity, {this.strict = true});
  final _HbBody body;
  final int arity;
  final bool strict;
}

final class _HbArray extends _HbObject {
  _HbArray(super.prototype);
  int length = 0;
}

final class _HbFixedPattern extends _HbObject {
  _HbFixedPattern(super.prototype, this.pattern) {
    define('lastIndex', 0, enumerable: false);
  }
  final String pattern;
}

final class _HbContainer extends _HbObject {
  _HbContainer(super.prototype, this.runtime);
  final _HbRuntime runtime;
}

// The value model retains own/non-enumerable fields, prototype identity and
// actual callable closures. It never encodes a function as a placeholder string.
final class _HbRuntime {
  _HbRuntime() {
    objectPrototype = _HbObject(null);
    functionPrototype = _HbFunction(objectPrototype, (_, _) => _hbUndefined, 0);
    functionPrototype.define('length', 0, enumerable: false);
    functionPrototype.define(
      'name',
      _hbUndefined,
      enumerable: false,
      getter: (_) => _reflection('Function name reflection'),
    );
    arrayPrototype = _HbArray(objectPrototype);
    stringPrototype = _HbObject(objectPrototype);
    numberPrototype = _HbObject(objectPrototype);
    booleanPrototype = _HbObject(objectPrototype);
    regexpPrototype = _HbObject(objectPrototype);
    objectPrototype.define(
      '__proto__',
      _hbUndefined,
      enumerable: false,
      getter: (value) => value is _HbObject
          ? value.prototype
          : value is String
          ? stringPrototype
          : value is num
          ? numberPrototype
          : value is bool
          ? booleanPrototype
          : _hbUndefined,
    );
    objectPrototype.define(
      'toString',
      function(
        (receiver, args) => receiver is _HbFunction
            ? '[object Function]'
            : receiver is _HbArray
            ? '[object Array]'
            : receiver == null
            ? '[object Null]'
            : ScriptCoercion.isUndefined(receiver)
            ? '[object Undefined]'
            : receiver is String
            ? '[object String]'
            : receiver is num
            ? '[object Number]'
            : receiver is bool
            ? '[object Boolean]'
            : '[object Object]',
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    objectPrototype.define(
      'valueOf',
      function(
        (receiver, args) {
          if (_hbNullish(receiver)) _hbFail('Cannot convert nullish receiver');
          return receiver;
        },
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    objectPrototype.define(
      'toLocaleString',
      function((receiver, args) => method(receiver, 'toString', []), 0, constructible: false),
      enumerable: false,
    );
    // The guard reads inherited values before deciding access. The AST visitor
    // also dispatches inherited Object methods directly, without that guard.
    for (final entry in const {
      'constructor': 1,
      '__defineGetter__': 2,
      '__defineSetter__': 2,
      '__lookupGetter__': 1,
      '__lookupSetter__': 1,
      'hasOwnProperty': 1,
      'isPrototypeOf': 1,
      'propertyIsEnumerable': 1,
    }.entries) {
      objectPrototype.define(
        entry.key,
        function(
          (receiver, args) {
            switch (entry.key) {
              case 'constructor':
                final value = _argument(args, 0);
                return _hbNullish(value) ? object() : value;
              case 'hasOwnProperty':
                return owns(receiver, propertyKey(_argument(args, 0)));
              case 'propertyIsEnumerable':
                final key = propertyKey(_argument(args, 0));
                return receiver is _HbObject
                    ? receiver.own[key]?.enumerable == true
                    : receiver is String && key != 'length' && owns(receiver, key);
              case 'isPrototypeOf':
                var value = _argument(args, 0);
                while (value is _HbObject) {
                  value = value.prototype;
                  if (identical(value, receiver)) return true;
                }
                return false;
              case '__lookupGetter__':
              case '__lookupSetter__':
                if (_hbNullish(receiver)) _hbFail('Nullish accessor lookup receiver');
                final key = propertyKey(_argument(args, 0));
                _HbObject? current = receiver is _HbObject
                    ? receiver
                    : receiver is String
                    ? stringPrototype
                    : receiver is num
                    ? numberPrototype
                    : booleanPrototype;
                while (current != null) {
                  final descriptor = current.own[key];
                  if (descriptor != null) {
                    if (entry.key == '__lookupSetter__') return descriptor.setterFunction ?? _hbUndefined;
                    if (descriptor.getterFunction != null) return descriptor.getterFunction;
                    if (descriptor.getter != null) {
                      return descriptor.getterFunction = function(
                        (value, args) => descriptor.getter!(value),
                        0,
                        constructible: false,
                      );
                    }
                    return _hbUndefined;
                  }
                  current = current.prototype;
                }
                return _hbUndefined;
              case '__defineGetter__':
              case '__defineSetter__':
                if (_hbNullish(receiver)) _hbFail('Nullish accessor definition receiver');
                final accessor = _argument(args, 1);
                if (accessor is! _HbFunction) _hbFail('Accessor must be callable');
                final key = propertyKey(_argument(args, 0));
                if (receiver is _HbObject) {
                  if (receiver.sealed) _hbFail('Accessor definition on sealed object');
                  final descriptor = receiver.own[key] ?? _HbOwn(_hbUndefined);
                  if (entry.key == '__defineGetter__') {
                    descriptor.getterFunction = accessor;
                  } else {
                    descriptor.setterFunction = accessor;
                  }
                  receiver.own[key] = descriptor;
                }
                return _hbUndefined;
              default:
                throw StateError('Unknown fixed Object intrinsic');
            }
          },
          entry.value,
          constructible: entry.key == 'constructor',
        ),
        enumerable: false,
      );
    }
    functionPrototype.define(
      'toString',
      function(
        (receiver, args) {
          if (receiver is! _HbFunction) _hbFail('Function receiver required');
          _reflection('Function source text');
        },
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    functionPrototype.define(
      'call',
      function(
        (receiver, args) {
          if (receiver is! _HbFunction) _hbFail('Function receiver required');
          return invoke(receiver, _argument(args, 0), args.skip(1).toList());
        },
        1,
        constructible: false,
      ),
      enumerable: false,
    );
    functionPrototype.define(
      'apply',
      function(
        (receiver, args) {
          if (receiver is! _HbFunction) _hbFail('Function receiver required');
          final list = _argument(args, 1);
          if (_hbNullish(list)) return invoke(receiver, _argument(args, 0), []);
          if (list is! _HbObject) _hbFail('Apply argument is not array-like');
          final length = _length(raw(list, 'length'));
          return invoke(receiver, _argument(args, 0), [for (var i = 0; i < length; i++) raw(list, '$i')]);
        },
        2,
        constructible: false,
      ),
      enumerable: false,
    );
    for (final key in const ['caller', 'arguments']) {
      functionPrototype.define(
        key,
        _hbUndefined,
        enumerable: false,
        getter: (_) => _hbFail('Restricted strict function property'),
      );
    }
    arrayPrototype.define(
      'join',
      function(
        (receiver, args) {
          if (_hbNullish(receiver)) _hbFail('Nullish join receiver');
          final length = _length(raw(receiver, 'length'));
          final separator = _argument(args, 0);
          final sep = ScriptCoercion.isUndefined(separator) ? ',' : string(separator);
          if (receiver is _HbArray && !_joining.add(receiver)) return '';
          try {
            final values = <String>[];
            for (var i = 0; i < length; i++) {
              final item = raw(receiver, '$i');
              values.add(_hbNullish(item) ? '' : string(item));
            }
            return values.join(sep);
          } finally {
            if (receiver is _HbArray) _joining.remove(receiver);
          }
        },
        1,
        constructible: false,
      ),
      enumerable: false,
    );
    arrayPrototype.define(
      'toString',
      function(
        (receiver, args) {
          final join = raw(receiver, 'join');
          return join is _HbFunction
              ? invoke(join, receiver, [])
              : invoke(raw(objectPrototype, 'toString'), receiver, []);
        },
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    arrayPrototype.define(
      'push',
      function(
        (receiver, args) {
          var length = _length(raw(receiver, 'length'));
          for (final item in args) {
            set(receiver, '${length++}', item);
          }
          set(receiver, 'length', length);
          return length;
        },
        1,
        constructible: false,
      ),
      enumerable: false,
    );
    arrayPrototype.define(
      'indexOf',
      function(
        (receiver, args) {
          final length = _length(raw(receiver, 'length'));
          final needle = _argument(args, 0);
          final n = number(_argument(args, 1));
          var start = n.isNaN
              ? 0
              : n.isInfinite
              ? n.isNegative
                    ? 0
                    : length
              : n.truncate();
          if (start < 0) start = (length + start).clamp(0, length).toInt();
          for (var i = start; i < length; i++) {
            if (_has(receiver, '$i') && strictEqual(raw(receiver, '$i'), needle)) return i;
          }
          return -1;
        },
        1,
        constructible: false,
      ),
      enumerable: false,
    );
    arrayPrototype.define(
      'splice',
      function(
        (receiver, args) {
          final length = _length(raw(receiver, 'length'));
          final relative = number(_argument(args, 0));
          final start = relative.isNaN
              ? 0
              : relative.isInfinite
              ? relative.isNegative
                    ? 0
                    : length
              : relative < 0
              ? (length + relative.truncate()).clamp(0, length).toInt()
              : relative.truncate().clamp(0, length).toInt();
          final requested = number(_argument(args, 1));
          final count = args.isEmpty
              ? 0
              : args.length == 1
              ? length - start
              : requested.isNaN || requested <= 0
              ? 0
              : requested.isInfinite
              ? length - start
              : requested.truncate().clamp(0, length - start).toInt();
          final added = args.skip(2).toList(), removed = array([]);
          for (var i = 0; i < count; i++) {
            if (_has(receiver, '${start + i}')) set(removed, '$i', raw(receiver, '${start + i}'));
          }
          set(removed, 'length', count);
          if (added.length < count) {
            for (var i = start; i < length - count; i++) {
              final from = '${i + count}', to = '${i + added.length}';
              if (_has(receiver, from)) {
                set(receiver, to, raw(receiver, from));
              } else {
                delete(receiver, to);
              }
            }
            for (var i = length; i > length - count + added.length; i--) {
              delete(receiver, '${i - 1}');
            }
          } else if (added.length > count) {
            for (var i = length - count; i > start; i--) {
              final from = '${i + count - 1}', to = '${i + added.length - 1}';
              if (_has(receiver, from)) {
                set(receiver, to, raw(receiver, from));
              } else {
                delete(receiver, to);
              }
            }
          }
          for (var i = 0; i < added.length; i++) {
            set(receiver, '${start + i}', added[i]);
          }
          set(receiver, 'length', length - count + added.length);
          return removed;
        },
        2,
        constructible: false,
      ),
      enumerable: false,
    );
    stringPrototype.define(
      'toString',
      function(
        (receiver, args) {
          if (receiver is! String) _hbFail('String receiver required');
          return receiver;
        },
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    stringPrototype.define('valueOf', raw(stringPrototype, 'toString'), enumerable: false);
    stringPrototype.define(
      'split',
      function(
        (receiver, args) {
          if (_hbNullish(receiver)) _hbFail('Nullish split receiver');
          final value = string(receiver);
          final separator = _argument(args, 0);
          if (ScriptCoercion.isUndefined(separator)) return array([value]);
          return array(value.split(string(separator)));
        },
        2,
        constructible: false,
      ),
      enumerable: false,
    );
    stringPrototype.define(
      'replace',
      function(
        (receiver, args) {
          if (_hbNullish(receiver)) _hbFail('Nullish replace receiver');
          final source = string(receiver), pattern = _argument(args, 0);
          final replacement = _argument(args, 1);
          final fixed = pattern is _HbFixedPattern ? pattern.pattern : null;
          int start, end;
          if (fixed == r'^\s+') {
            end = source.length - trimStartJsWhitespace(source).length;
            if (end == 0) return source;
            start = 0;
          } else if (fixed == r'\s+$') {
            start = trimEndJsWhitespace(source).length;
            if (start == source.length) return source;
            end = source.length;
          } else if (fixed != null) {
            final match = RegExp(fixed).firstMatch(source);
            if (match == null) return source;
            start = match.start;
            end = match.end;
          } else {
            final search = string(pattern);
            start = source.indexOf(search);
            // Native replace converts a non-function replacement even on a miss.
            final converted = replacement is _HbFunction ? null : string(replacement);
            if (start < 0) return source;
            end = start + search.length;
            final inserted = replacement is _HbFunction
                ? string(invoke(replacement, _hbUndefined, [search, start, source]))
                : _replacement(converted!, source, start, end);
            return '${source.substring(0, start)}$inserted${source.substring(end)}';
          }
          final inserted = replacement is _HbFunction
              ? string(invoke(replacement, _hbUndefined, [source.substring(start, end), start, source]))
              : _replacement(string(replacement), source, start, end);
          return '${source.substring(0, start)}$inserted${source.substring(end)}';
        },
        2,
        constructible: false,
      ),
      enumerable: false,
    );
    regexpPrototype.define(
      'toString',
      function(
        (receiver, args) {
          if (receiver is! _HbObject) _hbFail('RegExp toString receiver required');
          return '/${string(raw(receiver, 'source'))}/${string(raw(receiver, 'flags'))}';
        },
        0,
        constructible: false,
      ),
      enumerable: false,
    );
    regexpPrototype.define(
      'source',
      _hbUndefined,
      enumerable: false,
      getter: (receiver) {
        if (receiver is! _HbFixedPattern) _hbFail('RegExp source receiver required');
        return receiver.pattern;
      },
    );
    regexpPrototype.define(
      'flags',
      _hbUndefined,
      enumerable: false,
      getter: (receiver) {
        if (receiver is! _HbObject) _hbFail('RegExp flags receiver required');
        final result = StringBuffer();
        for (final entry in const {
          'hasIndices': 'd',
          'global': 'g',
          'ignoreCase': 'i',
          'multiline': 'm',
          'dotAll': 's',
          'unicode': 'u',
          'unicodeSets': 'v',
          'sticky': 'y',
        }.entries) {
          if (truthy(raw(receiver, entry.key))) result.write(entry.value);
        }
        return result.toString();
      },
    );
    for (final key in const [
      'hasIndices',
      'global',
      'ignoreCase',
      'multiline',
      'dotAll',
      'unicode',
      'unicodeSets',
      'sticky',
    ]) {
      regexpPrototype.define(
        key,
        _hbUndefined,
        enumerable: false,
        getter: (receiver) {
          if (receiver is! _HbFixedPattern) _hbFail('RegExp flag receiver required');
          return false;
        },
      );
    }
    for (final prototype in [numberPrototype, booleanPrototype]) {
      prototype.define(
        'valueOf',
        function(
          (receiver, args) {
            if (identical(prototype, numberPrototype) ? receiver is! num : receiver is! bool) {
              _hbFail('Primitive receiver required');
            }
            return receiver;
          },
          0,
          constructible: false,
        ),
        enumerable: false,
      );
      prototype.define(
        'toString',
        function(
          (receiver, args) {
            if (identical(prototype, numberPrototype) ? receiver is! num : receiver is! bool) {
              _hbFail('Primitive receiver required');
            }
            return ScriptCoercion.string(receiver);
          },
          0,
          constructible: false,
        ),
        enumerable: false,
      );
    }
    helpers = object();
    partials = object();
    decorators = object();
    nullContext = object()..sealed = true;
    noop = function((receiver, args) => '', 0);
    lookupFunction = function((receiver, args) => lookup(_argument(args, 0), _argument(args, 1)), 2);
    _installHelpers();
    hooks = object({'helperMissing': helperMissing, 'blockHelperMissing': blockHelperMissing});
    protoAccessControl = _makeProtoControl();
    environmentPartials = partials;
    environmentDecorators = decorators;
    container = _HbContainer(objectPrototype, this);
  }

  _HbRuntime.template(_HbRuntime parent) {
    objectPrototype = parent.objectPrototype;
    functionPrototype = parent.functionPrototype;
    arrayPrototype = parent.arrayPrototype;
    stringPrototype = parent.stringPrototype;
    numberPrototype = parent.numberPrototype;
    booleanPrototype = parent.booleanPrototype;
    regexpPrototype = parent.regexpPrototype;
    environmentHelpers = parent.environmentHelpers;
    environmentPartials = parent.environmentPartials;
    environmentDecorators = parent.environmentDecorators;
    matches = parent.matches;
    _joining = parent._joining;
    nullContext = object()..sealed = true;
    noop = parent.noop;
    lookupFunction = function((receiver, args) => lookup(_argument(args, 0), _argument(args, 1)), 2);
    helpers = parent.helpers;
    partials = parent.partials;
    decorators = parent.decorators;
    hooks = parent.hooks;
    helperMissing = parent.helperMissing;
    blockHelperMissing = parent.blockHelperMissing;
    protoAccessControl = parent.protoAccessControl;
    container = _HbContainer(objectPrototype, this);
  }

  late final _HbObject objectPrototype,
      functionPrototype,
      arrayPrototype,
      stringPrototype,
      numberPrototype,
      booleanPrototype,
      regexpPrototype;
  late final _HbObject nullContext;
  late Object? helpers, decorators, partials;
  late final _HbObject environmentHelpers;
  late final Object? environmentPartials, environmentDecorators;
  late final _HbContainer container;
  _HbObject? _templateSpec;
  late final _HbFunction noop, lookupFunction;
  late Object? helperMissing, blockHelperMissing, hooks, protoAccessControl;
  List<Object?> matches = [];
  Set<_HbArray> _joining = Set.identity();

  Never _reflection(String feature) => throw _scriptError(
    TavernScriptErrorCode.unsupportedCapability,
    'extractMessageBias',
    '$feature is not exposed by the fixed-source Handlebars backend.',
  );

  _HbObject object([Map<String, Object?> values = const {}]) {
    final result = _HbObject(objectPrototype);
    for (final entry in values.entries) {
      result.define(entry.key, entry.value);
    }
    return result;
  }

  _HbArray array(Iterable<Object?> items) {
    final result = _HbArray(arrayPrototype);
    for (final value in items) {
      result.define('${result.length++}', value);
    }
    return result;
  }

  _HbFunction function(_HbBody body, int arity, {bool constructible = true, bool strict = true}) {
    final result = _HbFunction(functionPrototype, body, arity, strict: strict);
    result.define('length', arity, enumerable: false);
    result.define('name', _hbUndefined, enumerable: false, getter: (_) => _reflection('Function name reflection'));
    if (!strict) {
      result.define('caller', null, enumerable: false);
      result.define('arguments', null, enumerable: false);
    }
    if (constructible) {
      final prototype = _HbObject(objectPrototype);
      prototype.define('constructor', result, enumerable: false);
      result.define('prototype', prototype, enumerable: false);
    }
    return result;
  }

  Object? _argument(List<Object?> values, int index) =>
      index >= 0 && index < values.length ? values[index] : _hbUndefined;

  bool truthy(Object? value) => value is _HbObject || ScriptCoercion.truthy(value);
  bool isEmpty(Object? value) => (!truthy(value) && value != 0) || (value is _HbArray && value.length == 0);

  Object? raw(Object? receiver, Object? field) {
    if (_hbNullish(receiver)) _hbFail('Property access on nullish value');
    final key = propertyKey(field);
    if (receiver is String) {
      if (key == 'length') return receiver.length;
      final index = ScriptCoercion.arrayIndex(key);
      if (index != null && index < receiver.length) return receiver.substring(index, index + 1);
    }
    if (receiver is _HbArray && key == 'length') return receiver.length;
    _HbObject? current = receiver is _HbObject
        ? receiver
        : receiver is String
        ? stringPrototype
        : receiver is num
        ? numberPrototype
        : receiver is bool
        ? booleanPrototype
        : null;
    while (current != null) {
      final property = current.own[key];
      if (property != null) {
        if (property.getterFunction != null) return invoke(property.getterFunction, receiver, []);
        if (property.setterFunction != null && property.getter == null) return _hbUndefined;
        return property.getter == null ? property.value : property.getter!(receiver);
      }
      current = current.prototype;
    }
    return _hbUndefined;
  }

  bool owns(Object? value, String key) {
    if (value is _HbArray && key == 'length') return true;
    if (value is _HbObject) return value.own.containsKey(key);
    if (value is String) {
      final index = ScriptCoercion.arrayIndex(key);
      return key == 'length' || (index != null && index < value.length);
    }
    return false;
  }

  Object? lookup(Object? receiver, Object? field) {
    // The fixed runtime reads the property before the own/prototype guard.
    final value = raw(receiver, field);
    if (_hbNullish(value) || owns(receiver, propertyKey(field))) return value;
    final access = _templateSpec == null ? protoAccessControl : raw(container, 'protoAccessControl');
    final control = raw(access, value is _HbFunction ? 'methods' : 'properties');
    if (!ScriptCoercion.isUndefined(raw(raw(control, 'whitelist'), field))) {
      return raw(raw(control, 'whitelist'), field) == true ? value : _hbUndefined;
    }
    final defaultValue = raw(control, 'defaultValue');
    if (!ScriptCoercion.isUndefined(defaultValue)) {
      return truthy(raw(control, 'defaultValue')) ? value : _hbUndefined;
    }
    if (!_hbLoggedProperties.contains(propertyKey(field))) {
      _hbLoggedProperties.add(propertyKey(field));
      // The warning interpolates the original value even with no console.
      string(field);
    }
    return _hbUndefined;
  }

  List<String> keys(Object? value) {
    final names = value is _HbObject
        ? [
            for (final e in value.own.entries)
              if (e.value.enumerable) e.key,
          ]
        : value is String
        ? [for (var i = 0; i < value.length; i++) '$i']
        : <String>[];
    final indexed = <(int, String)>[], other = <String>[];
    for (final name in names) {
      final index = ScriptCoercion.arrayIndex(name);
      if (index == null) {
        other.add(name);
      } else {
        indexed.add((index, name));
      }
    }
    indexed.sort((a, b) => a.$1.compareTo(b.$1));
    return [...indexed.map((e) => e.$2), ...other];
  }

  void set(Object? receiver, Object? field, Object? value) {
    if (_hbNullish(receiver)) _hbFail('Assignment on nullish value');
    final key = propertyKey(field);
    if (receiver is! _HbObject) _hbFail('Assignment on primitive value');
    if (receiver is _HbArray) {
      if (key == 'length') {
        final count = number(value);
        if (!count.isFinite || count < 0 || count > 4294967295 || count.truncateToDouble() != count) {
          _hbFail('Invalid array length');
        }
        receiver.length = count.toInt();
        receiver.own.removeWhere((name, _) {
          final index = ScriptCoercion.arrayIndex(name);
          return index != null && index >= receiver.length;
        });
        return;
      }
      final index = ScriptCoercion.arrayIndex(key);
      if (index != null && index >= receiver.length) receiver.length = index + 1;
    }
    final previous = receiver.own[key];
    if (previous != null) {
      if (previous.setterFunction != null) {
        invoke(previous.setterFunction, receiver, [value]);
        return;
      }
      if (previous.getter != null || previous.getterFunction != null) _hbFail('Assignment to accessor');
      previous.value = value;
      return;
    }
    if (key == '__proto__') {
      var prototype = receiver.prototype;
      var hasSetter = false;
      while (prototype != null) {
        if (identical(prototype, objectPrototype)) {
          hasSetter = true;
          break;
        }
        if (prototype.own.containsKey(key)) break;
        prototype = prototype.prototype;
      }
      if (hasSetter) {
        if (value == null || value is _HbObject) {
          var candidate = value as _HbObject?;
          while (candidate != null) {
            if (identical(candidate, receiver)) _hbFail('Cyclic prototype');
            candidate = candidate.prototype;
          }
          if (receiver.sealed && !identical(receiver.prototype, value)) {
            _hbFail('Prototype change on sealed object');
          }
          receiver.prototype = value;
        }
        return;
      }
    }
    if (receiver.sealed) _hbFail('New property on sealed object');
    receiver.define(key, value);
  }

  void delete(Object? receiver, String key) {
    if (_hbNullish(receiver)) _hbFail('Delete on nullish receiver');
    if (receiver is _HbObject) {
      if (receiver.sealed && receiver.own.containsKey(key)) _hbFail('Delete on sealed object');
      receiver.own.remove(key);
    } else if (receiver is String && owns(receiver, key)) {
      _hbFail('Delete string property');
    }
  }

  Object? replaceFixed(Object? receiver, String pattern) =>
      method(receiver, 'replace', [_HbFixedPattern(regexpPrototype, pattern), '']);
  String _replacement(String replacement, String source, int start, int end) {
    final result = StringBuffer();
    for (var i = 0; i < replacement.length; i++) {
      if (replacement.codeUnitAt(i) != 36 || i + 1 == replacement.length) {
        result.write(replacement[i]);
        continue;
      }
      final next = replacement[i + 1];
      if (next == r'$') {
        result.write(r'$');
        i++;
      } else if (next == '&') {
        result.write(source.substring(start, end));
        i++;
      } else if (next == '`') {
        result.write(source.substring(0, start));
        i++;
      } else if (next == "'") {
        result.write(source.substring(end));
        i++;
      } else {
        result.write(r'$');
      }
    }
    return result.toString();
  }

  _HbObject extend(_HbObject destination, Iterable<Object?> sources) {
    for (final source in sources) {
      for (final key in keys(source)) {
        set(destination, key, raw(source, key));
      }
    }
    return destination;
  }

  _HbObject frame(Object? source) => extend(object(), [source])..define('_parent', source);

  Object? invoke(Object? callable, Object? receiver, List<Object?> arguments) {
    if (callable is! _HbFunction) _hbFail('Value is not callable');
    return callable.body(receiver, arguments);
  }

  Object? method(Object? receiver, String name, List<Object?> arguments) =>
      invoke(raw(receiver, name), receiver, arguments);
  Object? primitive(Object? value, {bool stringHint = false}) {
    if (value is! _HbObject) return value;
    for (final key in stringHint ? const ['toString', 'valueOf'] : const ['valueOf', 'toString']) {
      final candidate = raw(value, key);
      if (candidate is _HbFunction) {
        final result = invoke(candidate, value, []);
        if (result is! _HbObject) return result;
      }
    }
    _hbFail('Cannot convert object to primitive');
  }

  String string(Object? value) {
    return ScriptCoercion.string(primitive(value, stringHint: true));
  }

  String propertyKey(Object? value) => string(primitive(value, stringHint: true));
  double number(Object? value) => ScriptCoercion.number(primitive(value));
  int _length(Object? value) {
    final n = number(value);
    if (n.isNaN || n <= 0) return 0;
    if (n >= 9007199254740991) return 9007199254740991;
    return n.floor();
  }

  Object? add(Object? left, Object? right) {
    final a = primitive(left), b = primitive(right);
    if (a is String || b is String) return '${string(a)}${string(b)}';
    return number(a) + number(b);
  }

  bool equal(Object? left, Object? right) {
    if (left is num && right is num) return left == right;
    if (identical(left, right)) return true;
    if (_hbNullish(left) && _hbNullish(right)) return true;
    if (left is String && right is String) return left == right;
    if (left is bool) return equal(left ? 1 : 0, right);
    if (right is bool) return equal(left, right ? 1 : 0);
    if ((left is String && right is num) || (left is num && right is String)) {
      return number(left) == number(right);
    }
    if (left is _HbObject && right is! _HbObject && !_hbNullish(right)) {
      return equal(primitive(left), right);
    }
    if (right is _HbObject && left is! _HbObject && !_hbNullish(left)) {
      return equal(left, primitive(right));
    }
    return false;
  }

  bool strictEqual(Object? left, Object? right) {
    if (left is num && right is num) return left == right;
    if (left is String && right is String) return left == right;
    if (left is bool && right is bool) return left == right;
    return identical(left, right);
  }

  Object? escape(Object? value) {
    if (value is! String) {
      if (truthy(value)) {
        final html = raw(value, 'toHTML');
        if (truthy(html)) return method(value, 'toHTML', []);
      }
      if (_hbNullish(value)) return '';
      if (!truthy(value)) return string(value);
      value = add('', value);
    }
    return (value as String).replaceAllMapped(
      RegExp(r'''[&<>"'`=]'''),
      (m) => const {
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#x27;',
        '`': '&#x60;',
        '=': '&#x3D;',
      }[m[0]]!,
    );
  }

  _HbObject blockArguments(List<Object?> values, List<Object?> paths) => array(values)..define('path', array(paths));
  Object? _contextPath(Object? parent, Object? id) => add(truthy(parent) ? add(parent, '.') : '', id);
  Object? _callOption(Object? options, String key, List<Object?> args) => invoke(raw(options, key), options, args);

  void _installHelpers() {
    final originals = object();
    environmentHelpers = originals;
    void register(String name, _HbBody body, int arity) {
      final original = function(body, arity);
      originals.define(name, original);
      final wrapper = function((receiver, args) {
        final options = _argument(args, args.length - 1);
        set(options, 'lookupProperty', lookupFunction);
        return invoke(original, receiver, args);
      }, 0);
      (helpers as _HbObject).define(name, wrapper);
    }

    register('helperMissing', (receiver, args) {
      if (args.length == 1) return _hbUndefined;
      // The actual error message reads options.name before throwing.
      add('Missing helper: "', raw(_argument(args, args.length - 1), 'name'));
      _hbFail('Missing helper');
    }, 0);
    register('blockHelperMissing', (receiver, args) {
      final context = _argument(args, 0);
      var options = _argument(args, 1);
      final inverse = raw(options, 'inverse'), fn = raw(options, 'fn');
      if (context == true) return invoke(fn, _hbUndefined, [receiver]);
      if (context == false || _hbNullish(context)) return invoke(inverse, _hbUndefined, [receiver]);
      if (context is _HbArray) {
        if (context.length == 0) return invoke(inverse, _hbUndefined, [receiver]);
        if (truthy(raw(options, 'ids'))) set(options, 'ids', array([raw(options, 'name')]));
        return invoke(raw(originals, 'each'), originals, [context, options]);
      }
      final data = raw(options, 'data');
      if (truthy(data) && truthy(raw(options, 'ids'))) {
        final next = frame(data);
        next.define('contextPath', _contextPath(raw(data, 'contextPath'), raw(options, 'name')));
        options = object({'data': next});
      }
      return invoke(fn, _hbUndefined, [context, options]);
    }, 2);
    register('if', (receiver, args) {
      if (args.length != 2) _hbFail('#if requires exactly one argument');
      var conditional = args[0];
      final options = args[1];
      if (conditional is _HbFunction) conditional = method(conditional, 'call', [receiver]);
      final zero = raw(raw(options, 'hash'), 'includeZero');
      return _callOption(options, (!truthy(zero) && !truthy(conditional)) || isEmpty(conditional) ? 'inverse' : 'fn', [
        receiver,
      ]);
    }, 2);
    register('unless', (receiver, args) {
      if (args.length != 2) _hbFail('#unless requires exactly one argument');
      final options = args[1];
      final callee = raw(originals, 'if'), call = raw(callee, 'call');
      final inverted = object({
        'fn': raw(options, 'inverse'),
        'inverse': raw(options, 'fn'),
        'hash': raw(options, 'hash'),
      });
      return invoke(call, callee, [receiver, args[0], inverted]);
    }, 2);
    register('with', (receiver, args) {
      if (args.length != 2) _hbFail('#with requires exactly one argument');
      var context = args[0];
      final options = args[1];
      if (context is _HbFunction) context = method(context, 'call', [receiver]);
      final fn = raw(options, 'fn');
      if (isEmpty(context)) return _callOption(options, 'inverse', [receiver]);
      var data = raw(options, 'data');
      final ids = raw(options, 'ids');
      if (truthy(data) && truthy(ids)) {
        final next = frame(data);
        next.define('contextPath', _contextPath(raw(data, 'contextPath'), raw(ids, '0')));
        data = next;
      }
      return invoke(fn, _hbUndefined, [
        context,
        object({
          'data': data,
          'blockParams': blockArguments([context], [truthy(data) ? raw(data, 'contextPath') : data]),
        }),
      ]);
    }, 2);
    register('each', (receiver, args) {
      var context = _argument(args, 0);
      final options = _argument(args, 1);
      if (!truthy(options)) _hbFail('Must pass iterator to #each');
      final fn = raw(options, 'fn'), inverse = raw(options, 'inverse');
      var count = 0;
      Object? result = '', data = _hbUndefined, contextPath = _hbUndefined;
      final originalData = raw(options, 'data'), ids = raw(options, 'ids');
      if (truthy(originalData) && truthy(ids)) {
        contextPath = add(_contextPath(raw(originalData, 'contextPath'), raw(ids, '0')), '.');
      }
      if (context is _HbFunction) context = method(context, 'call', [receiver]);
      if (truthy(originalData)) data = frame(originalData);
      void iteration(Object? field, int index, bool last) {
        if (truthy(data)) {
          set(data, 'key', field);
          set(data, 'index', index);
          set(data, 'first', index == 0);
          set(data, 'last', last);
          if (truthy(contextPath)) set(data, 'contextPath', add(contextPath, field));
        }
        // Both context[field] reads and the argument evaluation order are kept.
        final value = raw(context, field);
        final block = blockArguments([raw(context, field), field], [add(contextPath, field), null]);
        final child = invoke(fn, _hbUndefined, [
          value,
          object({'data': data, 'blockParams': block}),
        ]);
        result = add(result, child);
      }

      if (context is _HbArray) {
        final length = context.length;
        for (; count < length; count++) {
          if (_has(context, '$count')) iteration(count, count, count == context.length - 1);
        }
      } else if (context is _HbObject && context is! _HbFunction) {
        // Fresh template values have no Symbol keys or externally supplied
        // iterators. Arrays take the prior branch, as in the fixed helper.
        final names = keys(context);
        String? prior;
        for (final name in names) {
          if (prior != null) iteration(prior, count - 1, false);
          prior = name;
          count++;
        }
        if (prior != null) iteration(prior, count - 1, true);
      }
      if (count == 0) result = invoke(inverse, _hbUndefined, [receiver]);
      return result;
    }, 2);
    register('lookup', (receiver, args) {
      final value = _argument(args, 0);
      if (!truthy(value)) return value;
      return method(_argument(args, 2), 'lookupProperty', [value, _argument(args, 1)]);
    }, 3);
    register('log', (receiver, args) {
      final options = _argument(args, args.length - 1);
      var level = raw(raw(options, 'hash'), 'level');
      if (_hbNullish(level)) {
        final data = raw(options, 'data');
        level = truthy(data) && !_hbNullish(raw(data, 'level')) ? raw(data, 'level') : 1;
      }
      if (level is String) {
        final normalized = level.toLowerCase();
        final index = const ['debug', 'info', 'warn', 'error'].indexOf(normalized);
        if (index < 0) ScriptCoercion.parseInt10(level);
      }
      // logger.lookupLevel is evaluated. With no ambient console, its guarded
      // console branch is not entered; this leaf does not fabricate App logs.
      return _hbUndefined;
    }, 0);
    register('bias', (receiver, args) {
      matches.add(_argument(args, 0));
      return '';
    }, 1);
    helperMissing = raw(helpers, 'helperMissing')! as _HbFunction;
    blockHelperMissing = raw(helpers, 'blockHelperMissing')! as _HbFunction;
    (helpers as _HbObject).own.remove('helperMissing');
    (helpers as _HbObject).own.remove('blockHelperMissing');
    (decorators as _HbObject).define(
      'inline',
      function((receiver, args) {
        final fn = _argument(args, 0), props = _argument(args, 1), options = _argument(args, 3);
        final actualContainer = _argument(args, 2);
        Object? result = fn;
        if (!truthy(raw(props, 'partials'))) {
          set(props, 'partials', object());
          result = function((_, values) {
            final original = raw(actualContainer, 'partials');
            set(actualContainer, 'partials', extend(object(), [original, raw(props, 'partials')]));
            final rendered = invoke(fn, _hbUndefined, [_argument(values, 0), _argument(values, 1)]);
            // The fixed inline decorator intentionally has no finally here.
            set(actualContainer, 'partials', original);
            return rendered;
          }, 2);
        }
        set(raw(props, 'partials'), raw(raw(options, 'args'), '0'), raw(options, 'fn'));
        return result;
      }, 4),
    );
  }

  bool _has(Object? value, String key) {
    if (owns(value, key)) return true;
    var current = value is _HbObject ? value.prototype : null;
    while (current != null) {
      if (current.own.containsKey(key)) return true;
      current = current.prototype;
    }
    return false;
  }

  bool _in(Object? value, Object? field) {
    final key = propertyKey(field);
    if (value is! _HbObject) _hbFail('Right-hand side of in is not an object');
    return _has(value, key);
  }

  Object? _ownLookup(Object? value, Object? key) {
    if (!truthy(value)) return _hbUndefined;
    if (!owns(value, propertyKey(key))) return _hbUndefined;
    return raw(value, key);
  }

  Object? _option(List<Object?> arguments, int index) {
    final value = _argument(arguments, index);
    return ScriptCoercion.isUndefined(value) ? object() : value;
  }

  Object? _runDecorators(_HbCompiledProgram program, List<Object?> args) {
    Object? result = _argument(args, 0);
    final props = _argument(args, 1), actualContainer = _argument(args, 2);
    final table = raw(actualContainer, 'decorators');
    final scope = _HbScope(
      this,
      program,
      _argument(args, 3),
      _argument(args, 4),
      _argument(args, 5),
      _argument(args, 6),
      decorator: true,
      containerValue: actualContainer,
    );
    for (final plan in program.decorators) {
      final decorator = scope.lookup(table, _hbLoadJson(this, plan.name));
      if (decorator is! _HbFunction) _hbFail('Missing decorator');
      final options = plan.options.options(scope, objectArguments: true);
      final next = invoke(decorator, _hbUndefined, [result, props, actualContainer, options]);
      if (truthy(next)) result = next;
    }
    return result;
  }

  Object? _executeDecorators(
    Object? fn,
    Object? body,
    Object? actualContainer,
    Object? depths,
    Object? data,
    Object? blockParams,
  ) {
    if (!truthy(raw(fn, 'decorator'))) return body;
    final props = object();
    final result = method(fn, 'decorator', [
      body,
      props,
      actualContainer,
      truthy(depths) ? raw(depths, '0') : depths,
      data,
      blockParams,
      depths,
    ]);
    for (final key in keys(props)) {
      set(result, key, raw(props, key));
    }
    return result;
  }

  Object? _wrapValue(
    Object? actualContainer,
    Object? index,
    Object? fn,
    Object? data,
    Object? declaredBlockParams,
    Object? blockParams,
    Object? depths,
  ) {
    Object? wrapper = function((receiver, args) {
      final context = _argument(args, 0), options = _option(args, 1);
      var currentDepths = depths;
      if (truthy(depths) &&
          !equal(context, raw(depths, '0')) &&
          !(strictEqual(context, raw(actualContainer, 'nullContext')) && raw(depths, '0') == null)) {
        currentDepths = array([context, ..._concatValues(depths)]);
      }
      final actualHelpers = raw(actualContainer, 'helpers');
      final actualPartials = raw(actualContainer, 'partials');
      final suppliedData = raw(options, 'data');
      final actualBlocks = truthy(blockParams)
          ? array([raw(options, 'blockParams'), ..._concatValues(blockParams)])
          : blockParams;
      return invoke(fn, _hbUndefined, [
        actualContainer,
        context,
        actualHelpers,
        actualPartials,
        truthy(suppliedData) ? suppliedData : data,
        actualBlocks,
        currentDepths,
      ]);
    }, 1);
    wrapper = _executeDecorators(fn, wrapper, actualContainer, depths, data, blockParams);
    set(wrapper, 'program', index);
    set(wrapper, 'depth', truthy(depths) ? raw(depths, 'length') : 0);
    set(wrapper, 'blockParams', truthy(declaredBlockParams) ? declaredBlockParams : 0);
    return wrapper;
  }

  List<Object?> _arrayValues(Object? value) => [
    for (var i = 0, n = _length(raw(value, 'length')); i < n; i++) raw(value, '$i'),
  ];
  List<Object?> _concatValues(Object? value) => value is _HbArray ? _arrayValues(value) : [value];

  Object? render(_HbScope scope) {
    return scope.program.generated.run(scope);
  }

  String extract(_HbCompiledProgram program) {
    _bindProgram(program);
    _invokeTemplate(program, object(), object());
    if (matches.isEmpty) return '';
    final length = matches.length, values = <String>[];
    for (var i = 0; i < length; i++) {
      final value = matches[i];
      values.add(_hbNullish(value) ? '' : string(value));
    }
    return ' ${values.join(' ')}';
  }

  Object? partial(Object? value, Object? context, Object? options, {Object? actualContainer = _hbNotSupplied}) {
    if (identical(actualContainer, _hbNotSupplied)) actualContainer = container;
    final hash = raw(options, 'hash');
    if (truthy(hash)) {
      context = extend(object(), [context, hash]);
      final ids = raw(options, 'ids');
      if (truthy(ids)) set(ids, '0', true);
    }
    if (!truthy(value)) {
      value = raw(options, 'name') == '@partial-block'
          ? _ownLookup(raw(options, 'data'), 'partial-block')
          : _ownLookup(raw(options, 'partials'), raw(options, 'name'));
    } else if (!truthy(raw(value, 'call')) && !truthy(raw(options, 'name'))) {
      set(options, 'name', value);
      value = _ownLookup(raw(options, 'partials'), value);
    }
    set(options, 'hooks', raw(actualContainer, 'hooks'));
    set(options, 'protoAccessControl', raw(actualContainer, 'protoAccessControl'));
    final previousBlock = _ownLookup(raw(options, 'data'), 'partial-block');
    set(options, 'partial', true);
    final ids = raw(options, 'ids');
    if (truthy(ids)) {
      final first = raw(ids, '0'), data = raw(options, 'data');
      set(data, 'contextPath', truthy(first) ? first : raw(data, 'contextPath'));
    }
    Object? fallback = _hbUndefined;
    final fn = raw(options, 'fn');
    if (truthy(fn) && !identical(fn, noop)) {
      final data = frame(raw(options, 'data'));
      set(options, 'data', data);
      fallback = function((receiver, args) {
        final innerOptions = _option(args, 1);
        final innerData = frame(raw(innerOptions, 'data'));
        set(innerOptions, 'data', innerData);
        innerData.define('partial-block', previousBlock);
        return invoke(fn, _hbUndefined, [_argument(args, 0), innerOptions]);
      }, 1);
      data.define('partial-block', fallback);
      final localPartials = raw(fn, 'partials');
      if (truthy(localPartials)) {
        set(options, 'partials', extend(object(), [raw(options, 'partials'), localPartials]));
      }
    }
    if (ScriptCoercion.isUndefined(value) && truthy(fallback)) value = fallback;
    if (ScriptCoercion.isUndefined(value)) {
      add('The partial ', raw(options, 'name'));
      _hbFail('Missing partial');
    }
    var result = value is _HbFunction ? invoke(value, _hbUndefined, [context, options]) : _hbUndefined;
    if (_hbNullish(result)) {
      if (_hbNullish(value) || (value is! String && raw(value, 'type') != 'Program')) {
        // The fixed compiler formats the rejected input in its exception.
        // A reached function-source conversion still follows the explicit D
        // reflection boundary, even when it occurs while building an error.
        add('You must pass a string or Handlebars AST to Handlebars.compile. You passed ', value);
        _hbFail('Invalid partial compiler input');
      }
      final template = _compileTemplate(value);
      set(raw(options, 'partials'), raw(options, 'name'), template);
      result = invoke(raw(raw(options, 'partials'), raw(options, 'name')), raw(options, 'partials'), [
        context,
        options,
      ]);
    }
    if (_hbNullish(result)) _hbFail('Partial did not compile');
    final indent = raw(options, 'indent');
    if (truthy(indent)) {
      final lines = method(result, 'split', ['\n']);
      final length = raw(lines, 'length');
      for (var i = 0; i < number(length); i++) {
        final text = raw(lines, '$i');
        if (!truthy(text) && strictEqual(i + 1, length)) break;
        set(lines, '$i', add(indent, text));
      }
      result = method(lines, 'join', ['\n']);
    }
    return result;
  }

  _HbObject _makeProtoControl([Object? options]) {
    final properties = _HbObject(null)..define('__proto__', false);
    final methods = _HbObject(null);
    for (final key in const [
      'constructor',
      '__defineGetter__',
      '__defineSetter__',
      '__lookupGetter__',
      '__lookupSetter__',
    ]) {
      methods.define(key, false);
    }
    if (options != null) {
      extend(properties, [raw(options, 'allowedProtoProperties')]);
      extend(methods, [raw(options, 'allowedProtoMethods')]);
    }
    return object({
      'properties': object({
        'whitelist': properties,
        'defaultValue': options == null ? _hbUndefined : raw(options, 'allowProtoPropertiesByDefault'),
      }),
      'methods': object({
        'whitelist': methods,
        'defaultValue': options == null ? _hbUndefined : raw(options, 'allowProtoMethodsByDefault'),
      }),
    });
  }

  _HbFunction _compileTemplate(Object? input) {
    _HbCompiledProgram? compiled;
    _HbRuntime? runtime;
    void ensureCompiled() {
      if (compiled != null) return;
      compiled = input is String
          ? _HbCompiler().compile(_HbWhitespaceProgram.parse(input))
          : _HbRawCompiler(this).compile(input);
      runtime = _HbRuntime.template(this);
      runtime!._bindProgram(compiled!);
    }

    final ret = function((receiver, args) {
      ensureCompiled();
      return runtime!._invokeTemplate(compiled!, _argument(args, 0), _option(args, 1));
    }, 2);
    ret.define(
      '_setup',
      function((receiver, args) {
        ensureCompiled();
        runtime!._setupTemplate(compiled!, _argument(args, 0));
        return _hbUndefined;
      }, 1),
    );
    ret.define(
      '_child',
      function((receiver, args) {
        ensureCompiled();
        final blockParams = _argument(args, 2), depths = _argument(args, 3);
        if (compiled!.useBlockParams && !truthy(blockParams)) _hbFail('must pass block params');
        if (compiled!.useDepths && !truthy(depths)) _hbFail('must pass parent depths');
        final index = _argument(args, 0);
        return runtime!._wrapValue(
          runtime!.container,
          index,
          raw(runtime!._templateSpec, index),
          _argument(args, 1),
          0,
          blockParams,
          depths,
        );
      }, 4),
    );
    return ret;
  }

  void _bindProgram(_HbCompiledProgram program) {
    if (_templateSpec != null) return;
    final spec = object();
    _templateSpec = spec;
    _HbFunction generated(_HbCompiledProgram body) => function(
      (_, args) => render(
        _HbScope(
          this,
          body,
          _argument(args, 1),
          _argument(args, 4),
          _argument(args, 5),
          _argument(args, 6),
          containerValue: _argument(args, 0),
          helpersValue: _argument(args, 2),
          partialsValue: _argument(args, 3),
        ),
      ),
      body.useDepths
          ? 7
          : body.useBlockParams
          ? 6
          : 5,
      strict: false,
    );
    void addProgram(String name, _HbCompiledProgram body) {
      spec.define(name, generated(body));
      if (body.decorators.isNotEmpty) {
        spec.define('${name}_d', function((_, args) => _runDecorators(body, args), 7, strict: false));
      }
    }

    spec.define('compiler', array([8, '>= 4.3.0']));
    addProgram('main', program);
    for (final entry in program.children.entries) {
      addProgram('${entry.key}', entry.value);
    }
    if (program.useDecorators) spec.define('useDecorators', true);
    if (program.usePartial) spec.define('usePartial', true);
    spec.define('useData', true);
    if (program.useDepths) spec.define('useDepths', true);
    if (program.useBlockParams) spec.define('useBlockParams', true);
    final known = _HbObject(null);
    for (final name in _HbCompiler.known) {
      known.define(name, true);
    }
    spec.define('compilerOptions', object({'data': true, 'blockParams': array([]), 'knownHelpers': known}));
    set(raw(spec, 'main'), 'decorator', raw(spec, 'main_d'));
    container.define(
      'strict',
      function((_, args) {
        final value = _argument(args, 0), name = _argument(args, 1);
        if (!truthy(value) || !_in(value, name)) {
          add(add(add('"', name), '" not defined in '), value);
          _hbFail('Strict property is absent');
        }
        return method(container, 'lookupProperty', [value, name]);
      }, 3),
    );
    container.define('lookupProperty', lookupFunction);
    container.define(
      'lookup',
      function((_, args) {
        final depths = _argument(args, 0), name = _argument(args, 1);
        final length = raw(depths, 'length');
        for (var i = 0; i < number(length); i++) {
          final context = raw(depths, '$i');
          final found = truthy(context) ? method(container, 'lookupProperty', [raw(depths, '$i'), name]) : context;
          if (!_hbNullish(found)) return found;
        }
        return _hbUndefined;
      }, 2),
    );
    container.define(
      'lambda',
      function((_, args) {
        final value = _argument(args, 0);
        return value is _HbFunction ? method(value, 'call', [_argument(args, 1)]) : value;
      }, 2),
    );
    container.define('escapeExpression', function((_, args) => escape(_argument(args, 0)), 1));
    container.define(
      'invokePartial',
      function(
        (receiver, args) =>
            partial(_argument(args, 0), _argument(args, 1), _argument(args, 2), actualContainer: receiver),
        3,
      ),
    );
    container.define(
      'fn',
      function((_, args) {
        final index = _argument(args, 0), fn = raw(spec, _argument(args, 0));
        set(fn, 'decorator', raw(spec, add(index, '_d')));
        return fn;
      }, 1),
    );
    container.define('programs', array([]));
    container.define(
      'program',
      function((receiver, args) {
        final index = _argument(args, 0),
            data = _argument(args, 1),
            declared = _argument(args, 2),
            blocks = _argument(args, 3),
            depths = _argument(args, 4);
        Object? wrapper = raw(raw(receiver, 'programs'), index);
        final fn = method(receiver, 'fn', [index]);
        if (truthy(data) || truthy(depths) || truthy(blocks) || truthy(declared)) {
          wrapper = _wrapValue(receiver, index, fn, data, declared, blocks, depths);
        } else if (!truthy(wrapper)) {
          wrapper = _wrapValue(receiver, index, fn, _hbUndefined, _hbUndefined, _hbUndefined, _hbUndefined);
          set(raw(receiver, 'programs'), index, wrapper);
        }
        return wrapper;
      }, 5),
    );
    container.define(
      'data',
      function((_, args) {
        var value = _argument(args, 0), depth = number(_argument(args, 1));
        while (truthy(value) && depth != 0 && !depth.isNaN) {
          depth--;
          value = raw(value, '_parent');
        }
        return value;
      }, 2),
    );
    container.define(
      'mergeIfNeeded',
      function((_, args) {
        final supplied = _argument(args, 0), common = _argument(args, 1);
        return truthy(supplied) && truthy(common) && !strictEqual(supplied, common)
            ? extend(object(), [common, supplied])
            : truthy(supplied)
            ? supplied
            : common;
      }, 2),
    );
    container.define('nullContext', nullContext);
    container.define('noop', noop);
    container.define('compilerInfo', raw(spec, 'compiler'));
  }

  void _setupTemplate(_HbCompiledProgram program, Object? options) {
    if (!truthy(raw(options, 'partial'))) {
      final merged = object();
      void addHelpers(Object? table) {
        if (!truthy(table)) return;
        for (final key in keys(table)) {
          final original = raw(table, key);
          final capturedLookup = raw(container, 'lookupProperty');
          final replacement = original is! _HbFunction
              ? original
              : function((receiver, args) {
                  final helperOptions = _argument(args, args.length - 1);
                  set(helperOptions, 'lookupProperty', capturedLookup);
                  return invoke(original, receiver, args);
                }, 0);
          set(merged, key, replacement);
        }
      }

      addHelpers(environmentHelpers);
      addHelpers(raw(options, 'helpers'));
      helpers = merged;
      set(container, 'helpers', merged);
      if (program.usePartial) {
        final supplied = raw(options, 'partials');
        partials = method(container, 'mergeIfNeeded', [supplied, environmentPartials]);
        set(container, 'partials', partials);
      }
      if (program.usePartial || program.useDecorators) {
        decorators = extend(object(), [environmentDecorators, raw(options, 'decorators')]);
        set(container, 'decorators', decorators);
      }
      final actualHooks = object();
      hooks = actualHooks;
      set(container, 'hooks', actualHooks);
      protoAccessControl = _makeProtoControl(options);
      set(container, 'protoAccessControl', protoAccessControl);
      final keep = truthy(raw(options, 'allowCallsToHelperMissing'));
      for (final key in const ['helperMissing', 'blockHelperMissing']) {
        final helper = raw(merged, key);
        actualHooks.define(key, helper);
        if (!keep) merged.own.remove(key);
      }
    } else {
      protoAccessControl = raw(options, 'protoAccessControl');
      set(container, 'protoAccessControl', protoAccessControl);
      helpers = raw(options, 'helpers');
      set(container, 'helpers', helpers);
      partials = raw(options, 'partials');
      set(container, 'partials', partials);
      decorators = raw(options, 'decorators');
      set(container, 'decorators', decorators);
      hooks = raw(options, 'hooks');
      set(container, 'hooks', hooks);
    }
  }

  Object? _invokeTemplate(_HbCompiledProgram program, Object? context, Object? options) {
    var data = raw(options, 'data');
    _setupTemplate(program, options);
    if (!truthy(raw(options, 'partial'))) {
      if (!truthy(data) || !_in(data, 'root')) {
        data = truthy(data) ? frame(data) : object();
        set(data, 'root', context);
      }
    }
    final blocks = program.useBlockParams ? array([]) : _hbUndefined;
    Object? depths = _hbUndefined;
    if (program.useDepths) {
      if (truthy(raw(options, 'depths'))) {
        depths = !equal(context, raw(raw(options, 'depths'), '0'))
            ? array([context, ..._concatValues(raw(options, 'depths'))])
            : raw(options, 'depths');
      } else {
        depths = array([context]);
      }
    }
    Object? main = function(
      (receiver, args) => add(
        '',
        invoke(raw(_templateSpec, 'main'), _templateSpec, [
          container,
          _argument(args, 0),
          raw(container, 'helpers'),
          raw(container, 'partials'),
          data,
          blocks,
          depths,
        ]),
      ),
      1,
    );
    final specified = raw(options, 'depths');
    main = _executeDecorators(
      raw(_templateSpec, 'main'),
      main,
      container,
      truthy(specified) ? specified : array([]),
      data,
      blocks,
    );
    return invoke(main, _hbUndefined, [context, options]);
  }
}

abstract final class _HbWhitespaceProgram {
  static _HbProgram parse(String source) {
    final program = _HbParser(source).parse();
    _HbWhitespace().program(program);
    return program;
  }
}

Object? _hbJsonProjection(_HbRuntime rt, Object? root) {
  final active = Set<_HbObject>.identity();
  Object? project(Object? value, String key) {
    if (value is _HbObject) {
      final toJson = rt.raw(value, 'toJSON');
      if (toJson is _HbFunction) value = rt.invoke(toJson, value, [key]);
    }
    if (value is _HbFunction || ScriptCoercion.isUndefined(value)) return _hbUndefined;
    if (value is num && !value.isFinite) return null;
    if (value is! _HbObject) return value;
    if (!active.add(value)) _hbFail('Circular JSON source location');
    try {
      if (value is _HbArray) {
        final length = value.length, result = <Object?>[];
        for (var i = 0; i < length; i++) {
          final item = project(rt.raw(value, '$i'), '$i');
          result.add(ScriptCoercion.isUndefined(item) ? null : item);
        }
        return result;
      }
      final result = <String, Object?>{};
      for (final name in rt.keys(value)) {
        final item = project(rt.raw(value, name), name);
        if (!ScriptCoercion.isUndefined(item)) result[name] = item;
      }
      return result;
    } finally {
      active.remove(value);
    }
  }

  return project(root, '');
}

Object? _hbLoadJson(_HbRuntime rt, Object? value) {
  if (value is List<Object?>) return rt.array(value.map((item) => _hbLoadJson(rt, item)));
  if (value is Map<String, Object?>) {
    final result = rt.object();
    for (final entry in value.entries) {
      // JSON is emitted directly into generated JavaScript, rather than fed to
      // JSON.parse; an own __proto__ literal therefore sets its prototype.
      rt.set(result, entry.key, _hbLoadJson(rt, entry.value));
    }
    return result;
  }
  return value;
}

void _hbCheckSourceLocation(_HbSpan span) {
  final rt = span.sourceRuntime;
  if (rt == null || !rt.truthy(span.sourceLocation)) return;
  final start = rt.raw(span.sourceLocation, 'start');
  rt.raw(start, 'line');
  rt.raw(start, 'column');
}

// The official compile fallback also accepts pre-parsed Program objects. These
// are real values constructed by a template, not trusted parser DTOs.
void _hbValidateInputAst(_HbRuntime rt, Object? node) {
  if (_hbNullish(node)) return;
  if (node is _HbArray) {
    final length = node.length;
    for (var i = 0; i < length; i++) {
      if (rt._has(node, '$i')) _hbValidateInputAst(rt, rt.raw(node, '$i'));
    }
    return;
  }
  if (node is! _HbObject || node is _HbFunction) return;
  final type = rt.raw(node, 'type');
  if (type == 'PathExpression') {
    final depth = rt.raw(node, 'depth'), parts = rt.raw(node, 'parts');
    if (depth is! num || !depth.isFinite || depth < 0 || depth.floorToDouble() != depth) {
      _hbFail('Invalid AST path depth');
    }
    if (parts is! _HbArray) _hbFail('Invalid AST path parts');
    for (var i = 0; i < parts.length; i++) {
      if (rt.raw(parts, '$i') is! String) _hbFail('Invalid AST path part');
    }
  } else if (type == 'NumberLiteral') {
    final value = rt.raw(node, 'value');
    if (value is! num || !value.isFinite) _hbFail('Invalid AST NumberLiteral');
  } else if (type == 'BooleanLiteral') {
    if (rt.raw(node, 'value') is! bool) _hbFail('Invalid AST BooleanLiteral');
  }
  for (final key in rt.keys(node)) {
    if (key != 'loc') _hbValidateInputAst(rt, rt.raw(node, key));
  }
}

final class _HbRawWhitespace {
  _HbRawWhitespace(this.rt) {
    final prototype = rt.object({'parents': rt.array([]), 'mutating': false});
    state = rt.object({'options': rt.object()})..prototype = prototype;
  }
  final _HbRuntime rt;
  late final _HbObject state;
  static const _methods = {
    'Program',
    'BlockStatement',
    'DecoratorBlock',
    'PartialBlockStatement',
    'Decorator',
    'MustacheStatement',
    'PartialStatement',
    'CommentStatement',
    'ContentStatement',
    'SubExpression',
    'PathExpression',
    'StringLiteral',
    'NumberLiteral',
    'BooleanLiteral',
    'UndefinedLiteral',
    'NullLiteral',
    'Hash',
    'HashPair',
    'accept',
    'acceptKey',
    'acceptRequired',
    'acceptArray',
    'constructor',
  };

  Object? accept(Object? node) {
    if (!rt.truthy(node)) return _hbUndefined;
    final name = rt.propertyKey(rt.raw(node, 'type'));
    final inherited = _methods.contains(name) ? true : rt.raw(state, name);
    if (!rt.truthy(inherited)) {
      rt.add('Unknown type: ', rt.raw(node, 'type'));
      _hbFail('Unknown AST visitor type');
    }
    final current = rt.raw(state, 'current');
    final parents = rt.raw(state, 'parents');
    if (rt.truthy(current)) _unshift(parents, current);
    rt.set(state, 'current', node);
    final selected = rt.propertyKey(rt.raw(node, 'type'));
    final result = _visit(selected, node);
    rt.set(state, 'current', _shift(rt.raw(state, 'parents')));
    return result;
  }

  Object? _visit(String type, Object? node) {
    switch (type) {
      case 'Program':
        return _program(node);
      case 'BlockStatement':
      case 'DecoratorBlock':
      case 'PartialBlockStatement':
        return _block(node);
      case 'Decorator':
      case 'MustacheStatement':
        return rt.raw(node, 'strip');
      case 'PartialStatement':
      case 'CommentStatement':
        final value = rt.raw(node, 'strip');
        final strip = rt.truthy(value) ? value : rt.object();
        return rt.object({'inlineStandalone': true, 'open': rt.raw(strip, 'open'), 'close': rt.raw(strip, 'close')});
      case 'ContentStatement':
      case 'PathExpression':
      case 'StringLiteral':
      case 'NumberLiteral':
      case 'BooleanLiteral':
      case 'UndefinedLiteral':
      case 'NullLiteral':
        return _hbUndefined;
      case 'SubExpression':
        _required(node, 'path');
        _acceptArray(rt.raw(node, 'params'));
        accept(rt.raw(node, 'hash'));
        return _hbUndefined;
      case 'Hash':
        _acceptArray(rt.raw(node, 'pairs'));
        return _hbUndefined;
      case 'HashPair':
        _required(node, 'value');
        return _hbUndefined;
      case 'constructor':
        rt.set(state, 'parents', rt.array([]));
        return _hbUndefined;
      case 'accept':
        return accept(node);
      case 'acceptArray':
        _acceptArray(node);
        return _hbUndefined;
      case 'acceptKey':
        accept(rt.raw(node, _hbUndefined));
        return _hbUndefined;
      case 'acceptRequired':
        _required(node, _hbUndefined);
        return _hbUndefined;
      default:
        return rt.method(state, type, [node]);
    }
  }

  void _required(Object? node, Object? name) {
    accept(rt.raw(node, name));
    if (!rt.truthy(rt.raw(node, name))) {
      rt.add(rt.add(rt.raw(node, 'type'), ' requires '), name);
      _hbFail('Missing AST required field');
    }
  }

  void _acceptArray(Object? values) {
    Object? length = rt.raw(values, 'length');
    for (var i = 0; i < rt.number(length); i++) {
      accept(rt.raw(values, '$i'));
      if (!rt.truthy(rt.raw(values, '$i'))) {
        rt.method(values, 'splice', [i, 1]);
        i--;
        length = rt.number(length) - 1;
      }
    }
  }

  void _unshift(Object? values, Object? value) {
    if (values is! _HbArray) _hbFail('Invalid visitor parent stack');
    for (var i = values.length; i > 0; i--) {
      rt.set(values, '$i', rt.raw(values, '${i - 1}'));
    }
    rt.set(values, '0', value);
  }

  Object? _shift(Object? values) {
    if (values is! _HbArray) _hbFail('Invalid visitor parent stack');
    if (values.length == 0) return _hbUndefined;
    final first = rt.raw(values, '0');
    for (var i = 1; i < values.length; i++) {
      rt.set(values, '${i - 1}', rt.raw(values, '$i'));
    }
    rt.set(values, 'length', values.length - 1);
    return first;
  }

  Object? _program(Object? node) {
    final root = !rt.truthy(rt.raw(state, 'isRootSeen'));
    rt.set(state, 'isRootSeen', true);
    final body = rt.raw(node, 'body'), length = rt.raw(body, 'length');
    for (var i = 0; i < rt.number(length); i++) {
      final current = rt.raw(body, '$i'), strip = accept(current);
      if (!rt.truthy(strip)) continue;
      final previous = _previous(body, i, root), next = _next(body, i, root);
      final open = rt.truthy(rt.raw(strip, 'openStandalone')) && previous;
      final close = rt.truthy(rt.raw(strip, 'closeStandalone')) && next;
      final inline = rt.truthy(rt.raw(strip, 'inlineStandalone')) && previous && next;
      if (rt.truthy(rt.raw(strip, 'close'))) _omitRight(body, i, true);
      if (rt.truthy(rt.raw(strip, 'open'))) _omitLeft(body, i, true);
      if (inline) {
        _omitRight(body, i, false);
        if (_omitLeft(body, i, false) && rt.raw(current, 'type') == 'PartialStatement') {
          final original = rt.string(rt.raw(rt.raw(body, '${i - 1}'), 'original'));
          final match = RegExp(r'[ \t]+$').firstMatch(original);
          if (match == null) _hbFail('Invalid standalone partial indentation');
          rt.set(current, 'indent', match[0]!);
        }
      }
      if (open) {
        final main = rt.raw(current, 'program');
        _omitRight(rt.raw(rt.truthy(main) ? main : rt.raw(current, 'inverse'), 'body'), null, false);
        _omitLeft(body, i, false);
      }
      if (close) {
        _omitRight(body, i, false);
        final inverse = rt.raw(current, 'inverse');
        _omitLeft(rt.raw(rt.truthy(inverse) ? inverse : rt.raw(current, 'program'), 'body'), null, false);
      }
    }
    return node;
  }

  Object? _block(Object? node) {
    accept(rt.raw(node, 'program'));
    accept(rt.raw(node, 'inverse'));
    final firstProgram = rt.raw(node, 'program');
    final program = rt.truthy(firstProgram) ? firstProgram : rt.raw(node, 'inverse');
    final inverse = rt.truthy(firstProgram) ? rt.raw(node, 'inverse') : firstProgram;
    Object? firstInverse = inverse, lastInverse = inverse;
    if (rt.truthy(inverse) && rt.truthy(rt.raw(inverse, 'chained'))) {
      firstInverse = rt.raw(rt.raw(rt.raw(inverse, 'body'), '0'), 'program');
      while (rt.truthy(rt.raw(lastInverse, 'chained'))) {
        final body = rt.raw(lastInverse, 'body');
        lastInverse = rt.raw(rt.raw(body, rt.number(rt.raw(body, 'length')) - 1), 'program');
      }
    }
    final openStrip = rt.raw(node, 'openStrip'), closeStrip = rt.raw(node, 'closeStrip');
    final strip = rt.object({
      'open': rt.raw(openStrip, 'open'),
      'close': rt.raw(closeStrip, 'close'),
      'openStandalone': _next(rt.raw(program, 'body'), null, false),
      'closeStandalone': _previous(rt.raw(rt.truthy(firstInverse) ? firstInverse : program, 'body'), null, false),
    });
    if (rt.truthy(rt.raw(openStrip, 'close'))) _omitRight(rt.raw(program, 'body'), null, true);
    if (rt.truthy(inverse)) {
      final inverseStrip = rt.raw(node, 'inverseStrip');
      if (rt.truthy(rt.raw(inverseStrip, 'open'))) _omitLeft(rt.raw(program, 'body'), null, true);
      if (rt.truthy(rt.raw(inverseStrip, 'close'))) _omitRight(rt.raw(firstInverse, 'body'), null, true);
      if (rt.truthy(rt.raw(closeStrip, 'open'))) _omitLeft(rt.raw(lastInverse, 'body'), null, true);
      if (_previous(rt.raw(program, 'body'), null, false) && _next(rt.raw(firstInverse, 'body'), null, false)) {
        _omitLeft(rt.raw(program, 'body'), null, false);
        _omitRight(rt.raw(firstInverse, 'body'), null, false);
      }
    } else if (rt.truthy(rt.raw(closeStrip, 'open'))) {
      _omitLeft(rt.raw(program, 'body'), null, true);
    }
    return strip;
  }

  bool _previous(Object? body, int? i, bool root) {
    final position = i ?? rt.raw(body, 'length');
    final previous = rt.raw(body, rt.number(position) - 1);
    final sibling = rt.raw(body, rt.number(position) - 2);
    if (!rt.truthy(previous)) return root;
    if (rt.raw(previous, 'type') != 'ContentStatement') return false;
    final text = rt.string(rt.raw(previous, 'original'));
    var end = text.length;
    while (end > 0 && isJsWhitespace(text.codeUnitAt(end - 1))) {
      end--;
    }
    return (!rt.truthy(sibling) && root && end == 0) || text.substring(end).contains('\n');
  }

  bool _next(Object? body, int? i, bool root) {
    final position = i ?? -1;
    final next = rt.raw(body, '${position + 1}'), sibling = rt.raw(body, '${position + 2}');
    if (!rt.truthy(next)) return root;
    if (rt.raw(next, 'type') != 'ContentStatement') return false;
    final text = rt.string(rt.raw(next, 'original'));
    var end = 0;
    while (end < text.length && isJsWhitespace(text.codeUnitAt(end))) {
      end++;
    }
    return text.substring(0, end).contains('\n') || (!rt.truthy(sibling) && root && end == text.length);
  }

  void _omitRight(Object? body, int? i, bool multiple) {
    final current = rt.raw(body, i == null ? 0 : i + 1);
    if (!rt.truthy(current) ||
        rt.raw(current, 'type') != 'ContentStatement' ||
        (!multiple && rt.truthy(rt.raw(current, 'rightStripped')))) {
      return;
    }
    final before = rt.raw(current, 'value');
    final after = rt.replaceFixed(before, multiple ? r'^\s+' : r'^[ \t]*\r?\n?');
    rt.set(current, 'value', after);
    rt.set(current, 'rightStripped', !rt.strictEqual(after, before));
  }

  bool _omitLeft(Object? body, int? i, bool multiple) {
    final current = rt.raw(body, i == null ? rt.number(rt.raw(body, 'length')) - 1 : i - 1);
    if (!rt.truthy(current) ||
        rt.raw(current, 'type') != 'ContentStatement' ||
        (!multiple && rt.truthy(rt.raw(current, 'leftStripped')))) {
      return false;
    }
    final before = rt.raw(current, 'value');
    final after = rt.replaceFixed(before, multiple ? r'\s+$' : r'[ \t]+$');
    rt.set(current, 'value', after);
    final changed = !rt.strictEqual(after, before);
    rt.set(current, 'leftStripped', changed);
    return changed;
  }
}

// This is the fixed Compiler visitor on live AST objects. It deliberately
// preserves the separate validation, whitespace and compiler mutation phases.
final class _HbRawCompiler {
  _HbRawCompiler(this.rt) : state = rt.object();
  final _HbRuntime rt;
  final _HbObject state;
  final List<Object?> scopes = [];
  final List<Object?> sourceNodes = [];
  late _HbEnvironment env;
  static const methods = {
    'Program',
    'BlockStatement',
    'DecoratorBlock',
    'Decorator',
    'PartialStatement',
    'PartialBlockStatement',
    'MustacheStatement',
    'SubExpression',
    'ContentStatement',
    'CommentStatement',
    'PathExpression',
    'StringLiteral',
    'NumberLiteral',
    'BooleanLiteral',
    'NullLiteral',
    'UndefinedLiteral',
    'Hash',
    'equals',
    'compile',
    'compileProgram',
    'accept',
    'opcode',
    'addDepth',
    'classifySexpr',
    'pushParams',
    'pushParam',
    'setupFullMustacheParams',
    'blockParamIndex',
    'simpleSexpr',
    'ambiguousSexpr',
    'helperSexpr',
    'compiler',
  };

  _HbCompiledProgram compile(Object? input) {
    _hbValidateInputAst(rt, input);
    final parsed = _HbRawWhitespace(rt).accept(input);
    env = _HbEnvironment.raw()..sourceRuntime = rt;
    _accept(parsed);
    return _HbCompiler()._generate(env, -1);
  }

  void _emit(String opcode, [List<Object?> args = const []]) {
    final loc = rt.raw(sourceNodes.first, 'loc');
    env.emit(opcode, args, _HbSpan.raw(rt, loc));
  }

  void _accept(Object? node) {
    final first = rt.propertyKey(rt.raw(node, 'type'));
    if (!rt.truthy(_member(first))) {
      rt.add('Unknown type: ', rt.raw(node, 'type'));
      _hbFail('Unknown compiler AST type');
    }
    sourceNodes.insert(0, node);
    final type = rt.propertyKey(rt.raw(node, 'type'));
    switch (type) {
      case 'Program':
        scopes.insert(0, rt.raw(node, 'blockParams'));
        final body = rt.raw(node, 'body'), length = rt.raw(body, 'length');
        for (var i = 0; i < rt.number(length); i++) {
          _accept(rt.raw(body, '$i'));
        }
        scopes.removeAt(0);
        env.simple = rt.strictEqual(length, 1);
        final blockParams = rt.raw(node, 'blockParams');
        env.declaredBlockParams = rt.truthy(blockParams) ? rt.raw(blockParams, 'length') : 0;
      case 'BlockStatement':
        _transformPath(node);
        final main = _child(rt.raw(node, 'program'));
        final inverse = _child(rt.raw(node, 'inverse'));
        final kind = _classify(node);
        _sexpr(node, kind, main, inverse);
        if (kind != 'helper') {
          _emit('pushProgram', [main]);
          _emit('pushProgram', [inverse]);
          _emit('emptyHash', [false]);
          _emit(
            kind == 'simple' ? 'blockValue' : 'ambiguousBlockValue',
            kind == 'simple' ? [rt.raw(rt.raw(node, 'path'), 'original')] : const [],
          );
        }
        _emit('append');
      case 'DecoratorBlock':
      case 'Decorator':
        final main = _child(rt.raw(node, 'program'));
        final params = _setup(node, main, null);
        env.useDecorators = true;
        _emit('registerDecorator', [_count(params), rt.raw(rt.raw(node, 'path'), 'original')]);
      case 'PartialStatement':
      case 'PartialBlockStatement':
        env.usePartial = true;
        final main = _child(rt.raw(node, 'program'));
        final params = rt.raw(node, 'params'), length = rt.raw(params, 'length');
        if (rt.number(length) > 1) {
          rt.add('Unsupported number of partial arguments: ', length);
          _hbFail('Unsupported number of partial arguments');
        }
        if (!rt.truthy(length)) {
          rt.method(params, 'push', [
            rt.object({'type': 'PathExpression', 'parts': rt.array([]), 'depth': 0}),
          ]);
        }
        final name = rt.raw(node, 'name');
        final original = rt.raw(name, 'original');
        final dynamic = rt.raw(name, 'type') == 'SubExpression';
        if (dynamic) _accept(name);
        _setup(node, main, null, omitEmpty: true);
        final indent = rt.raw(node, 'indent');
        _emit('invokePartial', [dynamic, original, rt.truthy(indent) ? indent : '']);
        _emit('append');
      case 'MustacheStatement':
        _transformPath(node);
        _sexpr(node, _classify(node), null, null);
        _emit(rt.truthy(rt.raw(node, 'escaped')) ? 'appendEscaped' : 'append');
      case 'SubExpression':
        _transformPath(node);
        _sexpr(node, _classify(node), null, null);
      case 'ContentStatement':
        final value = rt.raw(node, 'value');
        if (rt.truthy(value)) _emit('appendContent', [value]);
      case 'CommentStatement':
        break;
      case 'PathExpression':
        _path(node);
      case 'StringLiteral':
        _emit('pushString', [rt.raw(node, 'value')]);
      case 'NumberLiteral':
      case 'BooleanLiteral':
        _emit('pushLiteral', [rt.raw(node, 'value')]);
      case 'NullLiteral':
        _emit('pushLiteral', [null]);
      case 'UndefinedLiteral':
        _emit('pushLiteral', [_hbUndefined]);
      case 'Hash':
        final pairs = rt.raw(node, 'pairs'), length = rt.raw(pairs, 'length');
        _emit('pushHash');
        var i = 0;
        for (; i < rt.number(length); i++) {
          _pushParam(rt.raw(rt.raw(pairs, '$i'), 'value'));
        }
        while (i > 0) {
          i--;
          _emit('assignToHash', [rt.raw(rt.raw(pairs, '$i'), 'key')]);
        }
        _emit('popHash');
      // Object.prototype methods can be named by an AST node. Their returned
      // value is ignored by Program, exactly like the fixed visitor dispatch.
      case 'constructor':
      case 'toString':
      case 'toLocaleString':
      case 'valueOf':
      case 'hasOwnProperty':
      case 'propertyIsEnumerable':
      case 'isPrototypeOf':
      case '__lookupGetter__':
      case '__lookupSetter__':
        rt.method(state, type, [node]);
      case '__defineGetter__':
      case '__defineSetter__':
        rt.method(state, type, [node]);
      case 'compiler':
        break;
      case 'accept':
        _accept(node);
      case 'addDepth':
        env.useDepths = true;
      case 'blockParamIndex':
        _blockParam(node);
      case 'pushParams':
        _pushParams(node);
      case 'pushParam':
        _pushParam(node);
      case 'simpleSexpr':
        _sexpr(node, 'simple', null, null);
      case 'ambiguousSexpr':
        _sexpr(node, 'ambiguous', null, null);
      case 'helperSexpr':
        _sexpr(node, 'helper', null, null);
      case 'classifySexpr':
        _classify(node);
      case 'setupFullMustacheParams':
        _setup(node, null, null);
      case 'compileProgram':
        _child(node);
      case 'compile':
        // This method is invoked with no options argument by accept(node).
        _hbFail('Compiler options are undefined');
      case 'equals':
        _equals(env, node);
      case 'opcode':
        env.opcodes.add(_HbOpcode(node, const [], _HbSpan.raw(rt, rt.raw(node, 'loc'))));
      default:
        rt.invoke(_member(type), state, [node]);
    }
    sourceNodes.removeAt(0);
  }

  Object? _member(String name) {
    if (methods.contains(name)) return true;
    if (name == 'opcodes' || name == 'children' || name == 'sourceNode' || name == 'options') return state;
    if (name == 'guid') return env.children.length;
    if (name == 'useDepths') return env.useDepths;
    if (name == 'usePartial') return env.usePartial;
    if (name == 'useDecorators') return env.useDecorators;
    if (name == 'isSimple') return env.simple;
    if (name == 'blockParams') return env.declaredBlockParams;
    return rt.raw(state, name);
  }

  Object? _child(Object? program) {
    if (!rt.truthy(program)) return program;
    final parent = env;
    env = _HbEnvironment.raw()..sourceRuntime = rt;
    _accept(program);
    final child = env;
    env = parent;
    final id = parent.children.length;
    parent.children.add(child);
    parent.usePartial = parent.usePartial || child.usePartial;
    parent.useDepths = parent.useDepths || child.useDepths;
    return id;
  }

  void _transformPath(Object? sexpr) {
    final literal = rt.raw(sexpr, 'path');
    if (!rt.truthy(rt.raw(literal, 'parts'))) {
      final part = rt.add(rt.raw(literal, 'original'), '');
      final original = rt.add(rt.raw(literal, 'original'), '');
      rt.set(
        sexpr,
        'path',
        rt.object({
          'type': 'PathExpression',
          'data': false,
          'depth': 0,
          'parts': rt.array([part]),
          'original': original,
          'loc': rt.raw(literal, 'loc'),
        }),
      );
    }
  }

  bool _scoped(Object? path) => RegExp(r'^\.|this\b').hasMatch(rt.string(rt.raw(path, 'original')));
  bool _simple(Object? path) =>
      rt.strictEqual(rt.raw(rt.raw(path, 'parts'), 'length'), 1) && !_scoped(path) && !rt.truthy(rt.raw(path, 'depth'));
  List<int>? _blockParam(Object? name) {
    for (var depth = 0; depth < scopes.length; depth++) {
      final params = scopes[depth];
      if (!rt.truthy(params)) continue;
      final length = rt.raw(params, 'length');
      for (var i = 0; i < rt.number(length); i++) {
        if (rt.strictEqual(rt.raw(params, '$i'), name)) return [depth, i];
      }
    }
    return null;
  }

  String _classify(Object? node) {
    final path = rt.raw(node, 'path');
    final simple = _simple(path);
    final bound = simple && _blockParam(rt.raw(rt.raw(path, 'parts'), '0')) != null;
    final type = rt.raw(node, 'type');
    var helper = false;
    if (!bound) {
      if (type == 'SubExpression') {
        helper = true;
      } else if (type == 'MustacheStatement' || type == 'BlockStatement') {
        final params = rt.raw(node, 'params');
        helper = rt.truthy(params) && rt.truthy(rt.raw(params, 'length'));
        if (!helper) helper = rt.truthy(rt.raw(node, 'hash'));
      }
    }
    final eligible = !bound && (helper || simple);
    if (eligible && !helper) {
      helper = _HbCompiler.known.contains(rt.propertyKey(rt.raw(rt.raw(path, 'parts'), '0')));
    }
    return helper
        ? 'helper'
        : eligible
        ? 'ambiguous'
        : 'simple';
  }

  void _sexpr(Object? node, String kind, Object? main, Object? inverse) {
    final path = rt.raw(node, 'path');
    if (kind == 'simple') {
      rt.set(path, 'strict', true);
      _accept(path);
      _emit('resolvePossibleLambda');
    } else if (kind == 'ambiguous') {
      final name = rt.raw(rt.raw(path, 'parts'), '0');
      _emit('getContext', [_depth(path)]);
      _emit('pushProgram', [main]);
      _emit('pushProgram', [inverse]);
      rt.set(path, 'strict', true);
      _accept(path);
      _emit('invokeAmbiguous', [name, !_hbNullish(main) || !_hbNullish(inverse)]);
    } else {
      final params = _setup(node, main, inverse);
      final actualPath = rt.raw(node, 'path');
      final name = rt.raw(rt.raw(actualPath, 'parts'), '0');
      if (_HbCompiler.known.contains(rt.propertyKey(name))) {
        _emit('invokeKnownHelper', [_count(params), name]);
      } else {
        rt.set(actualPath, 'strict', true);
        rt.set(actualPath, 'falsy', true);
        _accept(actualPath);
        _emit('invokeHelper', [_count(params), rt.raw(actualPath, 'original'), _simple(actualPath)]);
      }
    }
  }

  int _depth(Object? path) {
    final value = rt.raw(path, 'depth');
    if (value is! num || !value.isFinite || value < 0 || value.floorToDouble() != value) {
      _hbFail('Invalid generated path depth');
    }
    return value.toInt();
  }

  void _path(Object? path) {
    final depth = _depth(path);
    if (depth != 0) env.useDepths = true;
    _emit('getContext', [depth]);
    final rawParts = rt.raw(path, 'parts');
    final name = rt.raw(rawParts, '0'), scoped = _scoped(path);
    final bound = depth == 0 && !scoped ? _blockParam(name) : null;
    final parts = <String>[];
    final length = rt.raw(rawParts, 'length');
    for (var i = 0; i < rt.number(length); i++) {
      final part = rt.raw(rawParts, '$i');
      if (part is! String) _hbFail('Invalid generated path part');
      parts.add(part);
    }
    if (bound != null) {
      _emit('lookupBlockParam', [bound, parts]);
    } else if (!rt.truthy(name)) {
      _emit('pushContext');
    } else if (rt.truthy(rt.raw(path, 'data'))) {
      _emit('lookupData', [depth, parts, rt.truthy(rt.raw(path, 'strict'))]);
    } else {
      _emit('lookupOnContext', [parts, rt.truthy(rt.raw(path, 'falsy')), rt.truthy(rt.raw(path, 'strict')), scoped]);
    }
  }

  void _pushParam(Object? value) {
    // Even with both optional compiler flags false, the original reads these
    // fields before it dispatches the parameter node.
    final literal = rt.raw(value, 'value');
    if (_hbNullish(literal)) rt.raw(value, 'original');
    _accept(value);
  }

  void _pushParams(Object? params) {
    final length = rt.raw(params, 'length');
    for (var i = 0; i < rt.number(length); i++) {
      _pushParam(rt.raw(params, '$i'));
    }
  }

  Object? _count(Object? params) => rt.raw(params, 'length');
  bool _equals(_HbEnvironment current, Object? other) {
    final otherOpcodes = rt.raw(other, 'opcodes');
    if (!rt.strictEqual(rt.raw(otherOpcodes, 'length'), current.opcodes.length)) return false;
    for (var i = 0; i < current.opcodes.length; i++) {
      final opcode = current.opcodes[i], candidate = rt.raw(otherOpcodes, '$i');
      if (!rt.strictEqual(opcode.name, rt.raw(candidate, 'opcode')) ||
          !_argumentsEqual(opcode.arguments, rt.raw(candidate, 'args'))) {
        return false;
      }
    }
    for (var i = 0; i < current.children.length; i++) {
      if (!_equals(current.children[i], rt.raw(rt.raw(other, 'children'), '$i'))) return false;
    }
    return true;
  }

  bool _argumentsEqual(Object? actual, Object? other) {
    if (rt.strictEqual(actual, other)) return true;
    if (actual is List<Object?> && other is _HbArray && actual.length == other.length) {
      for (var i = 0; i < actual.length; i++) {
        if (!_argumentsEqual(actual[i], rt.raw(other, '$i'))) return false;
      }
      return true;
    }
    return false;
  }

  Object? _setup(Object? node, Object? main, Object? inverse, {bool omitEmpty = false}) {
    final params = rt.raw(node, 'params');
    _pushParams(params);
    _emit('pushProgram', [main]);
    _emit('pushProgram', [inverse]);
    final hash = rt.raw(node, 'hash');
    if (rt.truthy(hash)) {
      _accept(hash);
    } else {
      _emit('emptyHash', [omitEmpty]);
    }
    return params;
  }
}

// Backend D: decode only a single static primitive at the actual generated
// program-expression argument slot. This is not a JavaScript evaluator. The
// String conversion is intentionally before classification of its source.
Object? _hbProgramArgument(_HbRuntime rt, Object? value, {required bool followedByArgument}) {
  final source = _hbTrimSourceComments(_hbNullish(value) ? '' : rt.string(value));
  if (source.isEmpty) {
    if (followedByArgument) _hbFail('Empty generated argument before another argument');
    return _hbUndefined; // Legal final trailing comma in the generated call.
  }
  if (source == 'null') return null;
  if (source == 'undefined') return _hbUndefined;
  if (source == 'true') return true;
  if (source == 'false') return false;
  if (source == 'NaN') return double.nan;
  if (source == 'Infinity' || source == '+Infinity') return double.infinity;
  if (source == '-Infinity') return double.negativeInfinity;
  if (source.startsWith('"') || source.startsWith("'")) {
    final decoded = _hbJsStringLiteral(source);
    if (decoded != null) return decoded;
  } else {
    var numeric = source, sign = 1.0;
    if (numeric.startsWith('+') || numeric.startsWith('-')) {
      if (numeric.startsWith('-')) sign = -1.0;
      numeric = trimStartJsWhitespace(numeric.substring(1));
    }
    if (RegExp(r'^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$').hasMatch(numeric)) {
      if (RegExp(r'^0[0-7]+$').hasMatch(numeric)) {
        return sign * _hbRadixNumber(numeric, 8);
      }
      final parsed = double.tryParse(numeric);
      if (parsed != null) return sign * parsed;
    }
    for (final entry in const {'0x': 16, '0X': 16, '0b': 2, '0B': 2, '0o': 8, '0O': 8}.entries) {
      if (numeric.startsWith(entry.key) && numeric.length > 2) {
        final digits = numeric.substring(2);
        if (digits.codeUnits.every((unit) => _hbDigit(unit) >= 0 && _hbDigit(unit) < entry.value)) {
          return sign * _hbRadixNumber(digits, entry.value);
        }
      }
    }
  }
  throw _scriptError(
    TavernScriptErrorCode.unsupportedCapability,
    'extractMessageBias',
    'The reached Handlebars child-program source argument requires JavaScript '
        'evaluation beyond a single static primitive literal.',
  );
}

int _hbDigit(int unit) => unit >= 48 && unit <= 57
    ? unit - 48
    : unit >= 65 && unit <= 70
    ? unit - 55
    : unit >= 97 && unit <= 102
    ? unit - 87
    : -1;
double _hbRadixNumber(String source, int radix) {
  var value = 0.0;
  for (final unit in source.codeUnits) {
    value = value * radix + _hbDigit(unit);
  }
  return value;
}

String _hbTrimSourceComments(String source) {
  final result = StringBuffer();
  var i = 0, quote = 0;
  while (i < source.length) {
    final unit = source.codeUnitAt(i);
    if (quote != 0) {
      result.writeCharCode(unit);
      i++;
      if (unit == 92 && i < source.length) {
        result.writeCharCode(source.codeUnitAt(i++));
      } else if (unit == quote) {
        quote = 0;
      }
      continue;
    }
    if (unit == 34 || unit == 39 || unit == 96) {
      quote = unit;
      result.writeCharCode(unit);
      i++;
      continue;
    }
    if (source.startsWith('/*', i)) {
      final close = source.indexOf('*/', i + 2);
      if (close < 0) _hbFail('Unterminated generated source comment');
      result.write(' ');
      i = close + 2;
      continue;
    }
    if (source.startsWith('//', i)) {
      var close = i + 2;
      while (close < source.length && !const [10, 13, 8232, 8233].contains(source.codeUnitAt(close))) {
        close++;
      }
      if (close == source.length) {
        // It also comments out the generated closing parenthesis.
        _hbFail('Generated line comment consumes the closing call');
      }
      result.write(' ');
      i = close;
      continue;
    }
    result.writeCharCode(unit);
    i++;
  }
  return trimEndJsWhitespace(trimStartJsWhitespace(result.toString()));
}

String? _hbJsStringLiteral(String source) {
  final quote = source.codeUnitAt(0), result = StringBuffer();
  var i = 1;
  while (i < source.length) {
    var unit = source.codeUnitAt(i++);
    if (unit == quote) {
      return i == source.length ? result.toString() : null;
    }
    if (unit == 10 || unit == 13) _hbFail('Unescaped line terminator in generated string');
    if (unit != 92) {
      result.writeCharCode(unit);
      continue;
    }
    if (i == source.length) _hbFail('Unterminated generated string escape');
    unit = source.codeUnitAt(i++);
    if (unit == 10 || unit == 8232 || unit == 8233) continue;
    if (unit == 13) {
      if (i < source.length && source.codeUnitAt(i) == 10) i++;
      continue;
    }
    final simple = const {98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11}[unit];
    if (simple != null) {
      result.writeCharCode(simple);
      continue;
    }
    if (unit == 120 || unit == 117) {
      var count = unit == 120 ? 2 : 4, code = 0;
      if (unit == 117 && i < source.length && source.codeUnitAt(i) == 123) {
        i++;
        final start = i;
        while (i < source.length && _hbDigit(source.codeUnitAt(i)) >= 0) {
          code = code * 16 + _hbDigit(source.codeUnitAt(i++));
          if (code > 0x10ffff) _hbFail('Out-of-range generated Unicode escape');
        }
        if (i == start || i >= source.length || source.codeUnitAt(i++) != 125) {
          _hbFail('Invalid generated Unicode escape');
        }
      } else {
        while (count-- > 0) {
          if (i >= source.length || _hbDigit(source.codeUnitAt(i)) < 0) {
            _hbFail('Invalid generated hexadecimal escape');
          }
          code = code * 16 + _hbDigit(source.codeUnitAt(i++));
        }
      }
      result.writeCharCode(code);
      continue;
    }
    if (unit >= 48 && unit <= 55) {
      var code = unit - 48, count = unit <= 51 ? 2 : 1;
      while (count > 0 && i < source.length && source.codeUnitAt(i) >= 48 && source.codeUnitAt(i) <= 55) {
        code = code * 8 + source.codeUnitAt(i++) - 48;
        count--;
      }
      result.writeCharCode(code);
      continue;
    }
    // Sloppy generated Functions permit non-escape characters, including 8/9.
    result.writeCharCode(unit);
  }
  _hbFail('Unterminated generated string literal');
}
