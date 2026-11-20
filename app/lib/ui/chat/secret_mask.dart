// SPDX-FileCopyrightText: 2026 DeepSeek
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: one forward pass over the whole text; Flutter rendering (an
// inline mono chip per value, marks painted at the middle of the line).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/l10n.dart';
import '../theme/theme.dart';

/// 已发送用户文本里的一段可识别凭据:原文 `text[start, end)` 和它的显示形式。
///
/// 遮挡只改显示:消息原文、复制、编辑、发给模型的内容都不变。
@immutable
class SecretSpan {
  const SecretSpan(this.start, this.end, this.masked);

  final int start;
  final int end;

  /// 密钥 / 令牌保留前八个字符,私钥块保留 BEGIN / END 两行,地址里的密码
  /// 全遮;换行原样保留,其余每个字符(代码点)一个 `*`。
  final String masked;

  @override
  bool operator ==(Object other) =>
      other is SecretSpan && other.start == start && other.end == end && other.masked == masked;

  @override
  int get hashCode => Object.hash(start, end, masked);

  @override
  String toString() => 'SecretSpan($start, $end, $masked)';
}

/// [text] 里所有可识别的凭据,按位置排列、互不重叠。
///
/// 范围同官方:`sk-…`(至少一个数字)、`AIza…`、`ghp_` `github_pat_`
/// `glpat-` `npm_` `hf_`、`AKIA` `ASIA` `LTAI` `AKID`、`xoxb-` `sk_live_`
/// `rk_test_` `whsec_`、JWT、`-----BEGIN … PRIVATE KEY-----` 块、
/// `scheme://user:password@host` 的密码。`password=…` 这类赋值没有公开格式,
/// 不遮。
///
/// 线性:字面量扫描找候选起点,格式检查只做有界比较和"一类字符的连续段",
/// 段尾、下一个数字、下一个 `END` 行按文本记忆,没有可回溯的部分。
List<SecretSpan> findSecrets(String text) {
  final spans = <SecretSpan>[];
  final scanner = _Scanner(text);
  for (var span = scanner.match(0); span != null; span = scanner.match(span.end)) {
    spans.add(span);
  }
  return spans;
}

/// [text] 的显示形式:每段凭据换成 [SecretSpan.masked],遮挡的字符画成
/// [mark]。
String maskSecrets(String text, {List<SecretSpan>? secrets, String mark = '*'}) {
  secrets ??= findSecrets(text);
  if (secrets.isEmpty) return text;
  final out = StringBuffer();
  var at = 0;
  for (final secret in secrets) {
    out
      ..write(text.substring(at, secret.start))
      ..write(mark == '*' ? secret.masked : secret.masked.replaceAll('*', mark));
    at = secret.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

// ---------------------------------------------------------------------------
// 格式表

// ASCII code unit classes, as bits.
const _key = 1; // [A-Za-z0-9_-]
const _alnum = 2; // [A-Za-z0-9]
const _word = 4; // \w
const _alnumDash = 8; // [A-Za-z0-9-]
const _upperAlnum = 16; // [A-Z0-9]
const _label = 32; // [A-Z0-9 ]
const _scheme = 64; // [a-z0-9+.-]
const _lower = 128; // [a-z]
const _user = 256; // [^\s/:@?#]
const _password = 512; // [^\s/@?#]

final Uint16List _classes = () {
  final classes = Uint16List(128);
  for (var c = 0; c < 128; c++) {
    final upper = c >= 0x41 && c <= 0x5A;
    final lower = c >= 0x61 && c <= 0x7A;
    final digit = c >= 0x30 && c <= 0x39;
    final alnum = upper || lower || digit;
    // `\s / @ ? #` end an address's user name and password; `:` ends the name.
    final authority = !((c >= 9 && c <= 13) || c == 0x20 || c == 0x2F || c == 0x40 || c == 0x3F || c == 0x23);
    classes[c] =
        (alnum || c == 0x5F || c == 0x2D ? _key : 0) |
        (alnum ? _alnum : 0) |
        (alnum || c == 0x5F ? _word : 0) |
        (alnum || c == 0x2D ? _alnumDash : 0) |
        (upper || digit ? _upperAlnum : 0) |
        (upper || digit || c == 0x20 ? _label : 0) |
        (lower || digit || c == 0x2B || c == 0x2E || c == 0x2D ? _scheme : 0) |
        (lower ? _lower : 0) |
        (authority && c != 0x3A ? _user : 0) |
        (authority ? _password : 0);
  }
  return classes;
}();

enum _Kind {
  /// A private key block from its `-----BEGIN` line.
  keyBlock,

  /// The password of an address that carries credentials.
  address,

  /// A provider key or token after its fixed prefix.
  prefixed,
}

enum _Shape {
  /// The whole run, at least `min`.
  run,

  /// `min` to `max`, then `\b`.
  bounded,

  /// At least `min`, with a digit among the first 256.
  sk,

  /// Exactly `min`.
  google,

  /// Three runs joined by `.eyJ` and `.`.
  jwt,
}

class _Format {
  const _Format(this.literal, this.kind) : shape = _Shape.run, run = 0, min = 0, max = 0;

  const _Format.prefixed(this.literal, this.shape, this.run, this.min, [this.max = 0]) : kind = _Kind.prefixed;

  /// ASCII literal the candidate begins with; no literal occurs inside another.
  final String literal;
  final _Kind kind;
  final _Shape shape;

  /// Class bit of the run after the literal.
  final int run;
  final int min;
  final int max;
}

/// Every prefixed format matches more than the 8 characters a mask leaves
/// readable.
const _formats = <_Format>[
  _Format('-----BEGIN ', _Kind.keyBlock),
  _Format('://', _Kind.address),
  _Format.prefixed('sk-', _Shape.sk, _key, 20),
  _Format.prefixed('AIza', _Shape.google, _key, 35),
  _Format.prefixed('ghp_', _Shape.run, _alnum, 36),
  _Format.prefixed('gho_', _Shape.run, _alnum, 36),
  _Format.prefixed('ghu_', _Shape.run, _alnum, 36),
  _Format.prefixed('ghs_', _Shape.run, _alnum, 36),
  _Format.prefixed('ghr_', _Shape.run, _alnum, 36),
  _Format.prefixed('github_pat_', _Shape.run, _word, 22),
  _Format.prefixed('glpat-', _Shape.run, _key, 20),
  _Format.prefixed('npm_', _Shape.run, _alnum, 36),
  _Format.prefixed('hf_', _Shape.run, _alnum, 30),
  _Format.prefixed('AKIA', _Shape.bounded, _upperAlnum, 16, 16),
  _Format.prefixed('ASIA', _Shape.bounded, _upperAlnum, 16, 16),
  _Format.prefixed('LTAI', _Shape.bounded, _alnum, 12, 20),
  _Format.prefixed('AKID', _Shape.bounded, _alnum, 28, 36),
  _Format.prefixed('xoxa-', _Shape.run, _alnumDash, 10),
  _Format.prefixed('xoxb-', _Shape.run, _alnumDash, 10),
  _Format.prefixed('xoxp-', _Shape.run, _alnumDash, 10),
  _Format.prefixed('xoxr-', _Shape.run, _alnumDash, 10),
  _Format.prefixed('xoxs-', _Shape.run, _alnumDash, 10),
  _Format.prefixed('sk_live_', _Shape.run, _alnum, 16),
  _Format.prefixed('sk_test_', _Shape.run, _alnum, 16),
  _Format.prefixed('rk_live_', _Shape.run, _alnum, 16),
  _Format.prefixed('rk_test_', _Shape.run, _alnum, 16),
  _Format.prefixed('whsec_', _Shape.run, _alnum, 24),
  _Format.prefixed('eyJ', _Shape.jwt, _key, 8, 2048),
];

/// Formats by the first code unit of their literal.
final List<List<int>?> _byFirst = () {
  final table = List<List<int>?>.filled(128, null);
  for (var i = 0; i < _formats.length; i++) {
    (table[_formats[i].literal.codeUnitAt(0)] ??= []).add(i);
  }
  return table;
}();

/// Length of the longest proper suffix of each literal that begins a literal.
/// The scan resumes there, so a key block whose first dash ends `sk-` is
/// still seen.
final Uint8List _overlap = Uint8List.fromList([for (final format in _formats) _suffixOverlap(format.literal)]);

int _suffixOverlap(String literal) {
  for (var size = literal.length - 1; size > 0; size--) {
    final suffix = literal.substring(literal.length - size);
    if (_formats.any((f) => f.literal.startsWith(suffix))) return size;
  }
  return 0;
}

/// Prefixed formats leave this many leading characters readable.
const _visiblePrefix = 8;

// Memo layout: four `[A-Za-z0-9_-]` run pairs replaced in turn, then one pair
// per other run class, the next digit, and the next key-block `END` line.
const _keySlots = 0;
const _keyNext = 8;
const _alnumSlot = 9;
const _wordSlot = 11;
const _alnumDashSlot = 13;
const _upperAlnumSlot = 15;
const _userSlot = 17;
const _passwordSlot = 19;
const _digitFrom = 21;
const _digitAt = 22;
const _blockFrom = 23;
const _blockEndStart = 24;
const _blockEnd = 25;

/// Start of the password that the last address check accepted.
const _candidateStart = 26;
const _memoSize = 27;

/// `\s` above ASCII.
bool _isWideSpace(int c) =>
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    c == 0xFEFF;

/// One text's scanning state. Run ends, the next digit and the next key-block
/// `END` line are memoized, so each is measured once per text and the queries
/// of one pass cost, together, time linear in the text.
class _Scanner {
  _Scanner(this.text) : length = text.length;

  final String text;
  final int length;
  final Int32List _memo = Int32List(_memoSize)..fillRange(0, _memoSize, -1);

  /// Format of the literal [_nextLiteral] found last.
  int _found = 0;

  /// The nearest credential at or after [from]. Overlapping candidates of any
  /// format join the earliest one and take its mask, so no credential is drawn
  /// half masked. Candidates arrive in start order; an address password waits
  /// until the scan passes its start, and no other `://` can occur before
  /// then, because a user name and a password exclude `/`. A password that
  /// starts inside a range also ends inside it: the range holds the `:` before
  /// the password, so it is a key block, whose `END` line has spaces, or one
  /// that runs to the end of the text.
  SecretSpan? match(int from) {
    var start = -1;
    var end = -1;
    var kind = _Kind.prefixed;
    var plain = true;
    var deferredEnd = _addressBefore(from);
    var deferredStart = deferredEnd < 0 ? -1 : _memo[_candidateStart];
    var cursor = from;
    while (true) {
      if (end == length) break;
      final at = _nextLiteral(cursor);
      if (at < 0) break;
      final literal = _found;
      final format = _formats[literal];
      cursor = at + format.literal.length - _overlap[literal];
      if (deferredStart >= 0 && deferredStart <= at) {
        if (start < 0) {
          start = deferredStart;
          end = deferredEnd;
          kind = _Kind.address;
        } else if (deferredStart >= end) {
          break;
        }
        deferredStart = -1;
      }
      if (start >= 0 && at >= end) break;
      if (format.kind == _Kind.address) {
        deferredEnd = _addressPassword(at);
        deferredStart = deferredEnd < 0 ? -1 : _memo[_candidateStart];
        continue;
      }
      final candidateEnd = format.kind == _Kind.keyBlock ? _keyBlockEnd(at) : _prefixedEnd(format, at);
      if (candidateEnd < 0) continue;
      if (start < 0) {
        start = at;
        end = candidateEnd;
        kind = format.kind;
        plain = format.kind == _Kind.prefixed;
      } else if (candidateEnd > end) {
        end = candidateEnd;
        if (format.kind != _Kind.prefixed) plain = false;
      }
    }
    if (start < 0 && deferredStart >= 0) {
      start = deferredStart;
      end = deferredEnd;
      kind = _Kind.address;
    }
    if (start < 0) return null;
    return SecretSpan(start, end, _masked(kind, plain, start, end));
  }

  /// Offset of the first literal at or after [from], or -1; sets [_found].
  /// At most one literal starts at any offset.
  int _nextLiteral(int from) {
    for (var i = from; i < length; i++) {
      final c = text.codeUnitAt(i);
      if (c >= 128) continue;
      final candidates = _byFirst[c];
      if (candidates == null) continue;
      for (final candidate in candidates) {
        if (text.startsWith(_formats[candidate].literal, i)) {
          _found = candidate;
          return i;
        }
      }
    }
    return -1;
  }

  /// Code unit at [index]; -1 out of range.
  int _codeAt(int index) => index >= 0 && index < length ? text.codeUnitAt(index) : -1;

  /// `\w` at [index]; out of range is not a word character.
  bool _isWordAt(int index) {
    final c = _codeAt(index);
    return c >= 0 && c < 128 && _classes[c] & _word != 0;
  }

  /// `[^\s/:@?#]` for one code unit.
  bool _isUserCode(int c) => c < 128 ? _classes[c] & _user != 0 : !_isWideSpace(c);

  /// Offset after the run of [cls] characters at [start].
  int _runEnd(int cls, int start) {
    var i = start;
    if (cls == _user || cls == _password) {
      while (i < length) {
        final c = text.codeUnitAt(i);
        if (c < 128 ? _classes[c] & cls == 0 : _isWideSpace(c)) break;
        i++;
      }
    } else {
      while (i < length) {
        final c = text.codeUnitAt(i);
        if (c >= 128 || _classes[c] & cls == 0) break;
        i++;
      }
    }
    return i;
  }

  /// End of the `[A-Za-z0-9_-]` run at [start], through four memo pairs
  /// replaced in turn (a JWT measures three runs).
  int _keyRunEnd(int start) {
    for (var slot = _keySlots; slot < _keyNext; slot += 2) {
      if (_memo[slot] <= start && start <= _memo[slot + 1]) {
        return _memo[slot + 1];
      }
    }
    final end = _runEnd(_key, start);
    final next = (_memo[_keyNext] + 1) & 3;
    _memo[_keyNext] = next;
    _memo[_keySlots + 2 * next] = start;
    _memo[_keySlots + 2 * next + 1] = end;
    return end;
  }

  /// End of the run of [cls] at [start], through the memo pair at [slot].
  int _memoRunEnd(int cls, int slot, int start) {
    if (_memo[slot] <= start && start <= _memo[slot + 1]) {
      return _memo[slot + 1];
    }
    final end = _runEnd(cls, start);
    _memo[slot] = start;
    _memo[slot + 1] = end;
    return end;
  }

  int _classRunEnd(int cls, int start) => switch (cls) {
    _key => _keyRunEnd(start),
    _alnum => _memoRunEnd(cls, _alnumSlot, start),
    _word => _memoRunEnd(cls, _wordSlot, start),
    _alnumDash => _memoRunEnd(cls, _alnumDashSlot, start),
    _ => _memoRunEnd(cls, _upperAlnumSlot, start),
  };

  /// Offset of the first digit at or after [start], or the text length.
  int _nextDigit(int start) {
    if (_memo[_digitFrom] <= start && start <= _memo[_digitAt]) {
      return _memo[_digitAt];
    }
    var i = start;
    while (i < length) {
      final c = text.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) break;
      i++;
    }
    _memo[_digitFrom] = start;
    _memo[_digitAt] = i;
    return i;
  }

  /// Offset after `[A-Z0-9 ]{0,40}PRIVATE KEY-----` at [start], or -1; reads
  /// at most 52 characters.
  int _labelEnd(int start) {
    final limit = math.min(length, start + 52);
    var i = start;
    while (i < limit) {
      final c = text.codeUnitAt(i);
      if (c >= 128 || _classes[c] & _label == 0) break;
      i++;
    }
    final tail = i - 11;
    return i < start + 52 && tail >= start && text.startsWith('PRIVATE KEY-----', tail) ? tail + 16 : -1;
  }

  /// End of the `-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----` block at [at]:
  /// after its first complete `END` line, or the end of the text; -1 for an
  /// invalid header.
  int _keyBlockEnd(int at) {
    final header = _labelEnd(at + 11);
    if (header < 0) return -1;
    if (_memo[_blockFrom] <= header && header <= _memo[_blockEndStart]) {
      return _memo[_blockEnd];
    }
    _memo[_blockFrom] = header;
    _memo[_blockEndStart] = length;
    _memo[_blockEnd] = length;
    for (var line = text.indexOf('-----END ', header); line >= 0; line = text.indexOf('-----END ', line + 1)) {
      final end = _labelEnd(line + 9);
      if (end < 0) continue;
      _memo[_blockEndStart] = line;
      _memo[_blockEnd] = end;
      break;
    }
    return _memo[_blockEnd];
  }

  /// Whether `\b[a-z][a-z0-9+.-]{1,15}` ends at [at]; reads at most 16
  /// characters back.
  bool _schemeBefore(int at) {
    for (var start = at - 1; start >= 0 && start >= at - 16; start--) {
      final c = text.codeUnitAt(start);
      final bits = c < 128 ? _classes[c] : 0;
      if (bits & _scheme == 0) return false;
      if (bits & _lower != 0 && at - start >= 2 && !_isWordAt(start - 1)) {
        return true;
      }
    }
    return false;
  }

  /// The password in `\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@?#]{0,256}:[^\s/@?#]+@`
  /// for the `://` at [at]; neither part crosses `?` or `#`, where the
  /// authority ends. Returns the password end with its start in the memo, or
  /// -1.
  int _addressPassword(int at) {
    if (!_schemeBefore(at)) return -1;
    final userStart = at + 3;
    final userEnd = _memoRunEnd(_user, _userSlot, userStart);
    if (userEnd - userStart > 256 || _codeAt(userEnd) != 0x3A) return -1;
    final start = userEnd + 1;
    final end = _memoRunEnd(_password, _passwordSlot, start);
    if (end == start || _codeAt(end) != 0x40) return -1;
    _memo[_candidateStart] = start;
    return end;
  }

  /// The address password at or after [from] whose `://` starts before
  /// [from], as [_addressPassword] returns it. The walk back over the user
  /// name runs only when a `:`, a password and `@` follow.
  int _addressBefore(int from) {
    if (from < 3) return -1;
    if (text.startsWith('://', from - 1)) return _addressPassword(from - 1);
    if (text.startsWith('://', from - 2)) return _addressPassword(from - 2);
    var index = from - 1;
    final before = text.codeUnitAt(index);
    int passwordStart;
    if (before == 0x3A) {
      passwordStart = from;
      index--;
    } else if (_isUserCode(before)) {
      final userEnd = _memoRunEnd(_user, _userSlot, from);
      if (_codeAt(userEnd) != 0x3A) return -1;
      passwordStart = userEnd + 1;
    } else {
      return text.startsWith('://', from - 3) ? _addressPassword(from - 3) : -1;
    }
    final passwordEnd = _memoRunEnd(_password, _passwordSlot, passwordStart);
    if (passwordEnd == passwordStart || _codeAt(passwordEnd) != 0x40) {
      return -1;
    }
    final lowest = math.max(0, passwordStart - 258);
    while (index >= lowest && _isUserCode(text.codeUnitAt(index))) {
      index--;
    }
    return index >= 2 && text.startsWith('://', index - 2) ? _addressPassword(index - 2) : -1;
  }

  /// End of the prefixed credential whose literal starts at [at], or -1.
  int _prefixedEnd(_Format format, int at) {
    if (_isWordAt(at - 1)) return -1;
    final start = at + format.literal.length;
    final min = format.min;
    if (format.shape == _Shape.sk) {
      final digit = _nextDigit(start);
      if (digit - start > 255) return -1;
      final end = _keyRunEnd(start);
      return end - start >= min && digit < end ? end : -1;
    }
    final end = _classRunEnd(format.run, start);
    final length = end - start;
    if (length < min) return -1;
    switch (format.shape) {
      case _Shape.run:
        return end;
      case _Shape.google:
        return start + min;
      case _Shape.bounded:
        return length <= format.max && !_isWordAt(end) ? end : -1;
      case _Shape.jwt:
        if (length > format.max || !text.startsWith('.eyJ', end)) return -1;
        final payloadStart = end + 4;
        final payloadEnd = _keyRunEnd(payloadStart);
        if (payloadEnd - payloadStart < min || _codeAt(payloadEnd) != 0x2E) {
          return -1;
        }
        final signatureEnd = _keyRunEnd(payloadEnd + 1);
        return signatureEnd - (payloadEnd + 1) >= min ? signatureEnd : -1;
      case _Shape.sk:
        return -1;
    }
  }

  // -------------------------------------------------------------------------
  // 遮挡

  /// The display form of `text[start, end)`, whose earliest candidate has
  /// [kind]; [plain]: the range holds only prefixed-format characters (ASCII
  /// without line breaks).
  String _masked(_Kind kind, bool plain, int start, int end) {
    switch (kind) {
      case _Kind.address:
        return _marks(start, end);
      case _Kind.prefixed:
        final head = text.substring(start, start + _visiblePrefix);
        return plain ? head + '*' * (end - start - _visiblePrefix) : head + _marks(start + _visiblePrefix, end);
      case _Kind.keyBlock:
        return _keyBlock(start, end);
    }
  }

  /// Keep the `BEGIN` line, the `END` line when present, and every line
  /// break; a block written on one line is masked whole.
  String _keyBlock(int start, int end) {
    var bodyStart = start;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        bodyStart = i + 1;
        break;
      }
    }
    var bodyEnd = end;
    for (var i = end - 9; i >= bodyStart; i--) {
      if (text.codeUnitAt(i) == 0x0A && text.startsWith('-----END', i + 1)) {
        bodyEnd = i;
        break;
      }
    }
    return text.substring(start, bodyStart) + _marks(bodyStart, bodyEnd) + text.substring(bodyEnd, end);
  }

  /// `text[start, end)` with every character except line breaks replaced by
  /// `*`; a surrogate pair is one character.
  String _marks(int start, int end) {
    final out = StringBuffer();
    var count = 0;
    for (var i = start; i < end; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x0A || c == 0x0D) {
        out
          ..write('*' * count)
          ..writeCharCode(c);
        count = 0;
        continue;
      }
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < end) {
        final next = text.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) i++;
      }
      count++;
    }
    out.write('*' * count);
    return out.toString();
  }
}

// ---------------------------------------------------------------------------
// 显示

/// 用户文本,可识别的凭据遮挡显示;没有凭据时就是一个 [Text]。
///
/// 每段遮挡值用等宽字体画成一个行内块,显示 / 隐藏都不挪动周围文字。
/// [interactive](已发送的消息)时值后面带一个眼睛,点一下显示 / 隐藏这一段;
/// 每次挂载都从遮挡开始,同一位置换成另一个值也重新遮挡。乐观回显(发送中、
/// 排队中)只遮挡,不带控件。
class SecretText extends StatefulWidget {
  const SecretText(this.text, {super.key, required this.style, this.interactive = false});

  final String text;
  final TextStyle style;
  final bool interactive;

  @override
  State<SecretText> createState() => _SecretTextState();
}

class _SecretTextState extends State<SecretText> {
  late List<SecretSpan> _secrets = findSecrets(widget.text);

  /// 已显示的值:起点 → 当时的原文。记原文而不是开关,同一位置换了值就
  /// 从遮挡开始。
  final _revealed = <int, String>{};

  @override
  void didUpdateWidget(SecretText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _secrets = findSecrets(widget.text);
  }

  void _toggle(int start, String raw) {
    setState(() {
      if (_revealed[start] == raw) {
        _revealed.remove(start);
      } else {
        _revealed[start] = raw;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (_secrets.isEmpty) return Text(text, style: widget.style);
    final interactive = widget.interactive;
    final children = <InlineSpan>[];
    var at = 0;
    for (final secret in _secrets) {
      if (secret.start > at) {
        children.add(TextSpan(text: text.substring(at, secret.start)));
      }
      final raw = text.substring(secret.start, secret.end);
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _SecretValue(
            raw: raw,
            masked: secret.masked,
            revealed: interactive && _revealed[secret.start] == raw,
            onToggle: interactive ? () => _toggle(secret.start, raw) : null,
            style: widget.style,
          ),
        ),
      );
      at = secret.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: children), style: widget.style);
  }
}

/// 一段遮挡值:等宽,字号是正文的 0.875,行高与正文同一个像素值;交互时
/// 最后一个字符后面跟着眼睛。
class _SecretValue extends StatelessWidget {
  const _SecretValue({
    required this.raw,
    required this.masked,
    required this.revealed,
    required this.onToggle,
    required this.style,
  });

  final String raw;
  final String masked;
  final bool revealed;
  final VoidCallback? onToggle;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final bodySize = style.fontSize ?? 16;
    final line = bodySize * (style.height ?? 1.6);
    final size = bodySize * 0.875;
    final onToggle = this.onToggle;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: _MaskedValue(
        text: revealed ? raw : masked,
        masked: !revealed,
        style: AppType.mono(size: size, color: style.color, height: line / size),
        // 图标一个字高;点按区域左右各留 3,上下占满一行。
        eye: onToggle == null ? null : Size(size + 6, line),
        child: onToggle == null ? null : _EyeButton(revealed: revealed, size: size, onTap: onToggle),
      ),
    );
  }
}

/// 眼睛:显示 / 隐藏这一段。
class _EyeButton extends StatelessWidget {
  const _EyeButton({required this.revealed, required this.size, required this.onTap});

  final bool revealed;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      button: true,
      label: revealed ? l10n.activitySecretHide : l10n.activitySecretShow,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: CustomPaint(
            size: Size.square(size),
            painter: _EyePainter(color, crossed: revealed),
          ),
        ),
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.color, {required this.crossed});

  final Color color;

  /// 显示中:划掉的眼睛,去掉瞳孔,小字号下才分得清。
  final bool crossed;

  // viewBox 0 0 16 16,官方的 EYE_CONTOUR / EYE_PATH / EYE_OFF_PATH。
  static final _contour = Path()
    ..moveTo(1.5, 8)
    ..cubicTo(2.9, 5.25, 5.25, 3.5, 8, 3.5)
    ..cubicTo(10.75, 3.5, 13.1, 5.25, 14.5, 8)
    ..cubicTo(13.1, 10.75, 10.75, 12.5, 8, 12.5)
    ..cubicTo(5.25, 12.5, 2.9, 10.75, 1.5, 8)
    ..close();

  static final _eye = Path()
    ..addPath(_contour, Offset.zero)
    ..moveTo(10, 8)
    ..cubicTo(10, 9.1, 9.1, 10, 8, 10)
    ..cubicTo(6.9, 10, 6, 9.1, 6, 8)
    ..cubicTo(6, 6.9, 6.9, 6, 8, 6)
    ..cubicTo(9.1, 6, 10, 6.9, 10, 8)
    ..close();

  static final _eyeOff = Path()
    ..addPath(_contour, Offset.zero)
    ..moveTo(2.5, 2.5)
    ..lineTo(13.5, 13.5);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 16);
    canvas.drawPath(
      crossed ? _eyeOff : _eye,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_EyePainter old) => old.color != color || old.crossed != crossed;
}

/// 遮挡值的文字,[child](眼睛)排在最后一个字符后面,跟着换行走。
///
/// `*` 照常排版(换行、宽度、读屏都和字符一致),但不画字体自带的星号(它
/// 贴着大写字母顶部),而是在每格画官方的六角标记,垂直居中。不读
/// [MediaQuery] 的字号缩放:[WidgetSpan] 已经把整块按外层字号缩放过。
class _MaskedValue extends SingleChildRenderObjectWidget {
  const _MaskedValue({required this.text, required this.masked, required this.style, this.eye, super.child})
    : assert((eye == null) == (child == null));

  final String text;
  final bool masked;
  final TextStyle style;

  /// [child] 占的格子;null = 没有眼睛。
  final Size? eye;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMaskedValue(text: text, masked: masked, style: style, eye: eye, textDirection: Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, _RenderMaskedValue render) {
    render
      ..textDirection = Directionality.of(context)
      ..update(text: text, masked: masked, style: style, eye: eye);
  }
}

class _RenderMaskedValue extends RenderBox with RenderObjectWithChildMixin<RenderBox> {
  _RenderMaskedValue({
    required this.text,
    required this.masked,
    required this.style,
    required this.eye,
    required TextDirection textDirection,
  }) : _painter = TextPainter(textDirection: textDirection) {
    _sync();
  }

  String text;
  bool masked;
  TextStyle style;
  Size? eye;
  final TextPainter _painter;

  /// `*` 连续段的位置,画标记用。
  List<TextRange> _runs = const [];

  set textDirection(TextDirection value) {
    if (_painter.textDirection == value) return;
    _painter.textDirection = value;
    markNeedsLayout();
  }

  void update({required String text, required bool masked, required TextStyle style, required Size? eye}) {
    if (text == this.text && masked == this.masked && style == this.style && eye == this.eye) {
      return;
    }
    this.text = text;
    this.masked = masked;
    this.style = style;
    this.eye = eye;
    _sync();
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  void _sync() {
    final runs = <TextRange>[];
    if (masked) {
      var start = -1;
      for (var i = 0; i <= text.length; i++) {
        final star = i < text.length && text.codeUnitAt(i) == 0x2A;
        if (star && start < 0) start = i;
        if (!star && start >= 0) {
          runs.add(TextRange(start: start, end: i));
          start = -1;
        }
      }
    }
    _runs = runs;
    // 星号本身透明:保留它的排版,标记另外画。
    final hidden = style.copyWith(color: const Color(0x00000000));
    final children = <InlineSpan>[];
    var at = 0;
    for (final run in runs) {
      if (run.start > at) {
        children.add(TextSpan(text: text.substring(at, run.start)));
      }
      children.add(TextSpan(text: run.textInside(text), style: hidden));
      at = run.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    final eye = this.eye;
    if (eye != null) {
      // 占位与一行等高、按文字中线对齐:正好填满这一行,不撑高。
      children.add(const WidgetSpan(alignment: PlaceholderAlignment.middle, child: SizedBox.shrink()));
    }
    _painter.text = TextSpan(style: style, children: children);
    if (eye != null) {
      _painter.setPlaceholderDimensions([PlaceholderDimensions(size: eye, alignment: PlaceholderAlignment.middle)]);
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  void _layoutText(double maxWidth) => _painter.layout(maxWidth: maxWidth.isFinite ? maxWidth : double.infinity);

  @override
  double computeMinIntrinsicWidth(double height) {
    _layoutText(double.infinity);
    return _painter.minIntrinsicWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    _layoutText(double.infinity);
    return _painter.maxIntrinsicWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    _layoutText(width);
    return _painter.height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    _layoutText(constraints.maxWidth);
    return constraints.constrain(_painter.size);
  }

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    _layoutText(constraints.maxWidth);
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  void performLayout() {
    _layoutText(constraints.maxWidth);
    size = constraints.constrain(_painter.size);
    final child = this.child;
    final eye = this.eye;
    if (child != null && eye != null) {
      child.layout(BoxConstraints.tight(eye));
      final box = _painter.inlinePlaceholderBoxes!.single;
      (child.parentData! as BoxParentData).offset = Offset(box.left, box.top);
    }
    _layoutMarks();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    _layoutText(constraints.maxWidth);
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  /// 标记中心在基线以上多高(em):小写字母的中部,和官方相同。
  static const _markLift = 0.25;

  /// 所有标记,相对本框左上角;每次排版后重算,绘制时只画这一条路径。
  Path _marks = Path();
  double _markStroke = 0;

  /// 官方 SVG 标记:视图框 12×20,`M6 5.6v8.8 M2.19 7.8l7.62 4.4
  /// M2.19 12.2l7.62-4.4`,线宽 1.5;一格(一个字符宽)是 12 个单位。
  void _layoutMarks() {
    final marks = Path();
    if (_runs.isNotEmpty) {
      final em = style.fontSize ?? 14;
      final lines = _painter.computeLineMetrics();
      for (final run in _runs) {
        final boxes = _painter.getBoxesForSelection(TextSelection(baseOffset: run.start, extentOffset: run.end));
        // 等宽字体:每个 `*` 一格,格宽 = 总宽 / 个数。
        var width = 0.0;
        for (final box in boxes) {
          width += box.right - box.left;
        }
        final cell = width / (run.end - run.start);
        if (cell <= 0) continue;
        final u = cell / 12;
        _markStroke = 1.5 * u;
        for (final box in boxes) {
          final middle = (box.top + box.bottom) / 2;
          final line = lines.firstWhere((l) => middle <= l.baseline + l.descent, orElse: () => lines.last);
          final cy = line.baseline - em * _markLift;
          final count = ((box.right - box.left) / cell).round();
          for (var i = 0; i < count; i++) {
            final cx = box.left + (i + 0.5) * cell;
            marks
              ..moveTo(cx, cy - 4.4 * u)
              ..lineTo(cx, cy + 4.4 * u)
              ..moveTo(cx - 3.81 * u, cy - 2.2 * u)
              ..lineTo(cx + 3.81 * u, cy + 2.2 * u)
              ..moveTo(cx - 3.81 * u, cy + 2.2 * u)
              ..lineTo(cx + 3.81 * u, cy - 2.2 * u);
          }
        }
      }
    }
    _marks = marks;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _layoutText(constraints.maxWidth);
    final canvas = context.canvas;
    _painter.paint(canvas, offset);
    if (_runs.isNotEmpty) {
      canvas
        ..save()
        ..translate(offset.dx, offset.dy)
        ..drawPath(
          _marks,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = _markStroke
            ..color = style.color ?? const Color(0xFF000000)
            ..isAntiAlias = true,
        )
        ..restore();
    }
    final child = this.child;
    if (child != null) {
      context.paintChild(child, offset + (child.parentData! as BoxParentData).offset);
    }
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    final offset = (child.parentData! as BoxParentData).offset;
    return result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true
      ..label = text
      ..textDirection = _painter.textDirection;
  }
}
