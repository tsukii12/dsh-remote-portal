part of 'slash_language.dart';

class SlashDescriptor {
  const SlashDescriptor(
    this.canonical,
    this.named, {
    this.openNamed = false,
    this.splitUnnamed = false,
    this.splitCount,
    this.rawQuotes = false,
  });
  final String canonical;
  final Set<String> named;
  final bool openNamed, splitUnnamed, rawQuotes;
  final int? splitCount;
}

const _conditionNames = {'a', 'left', 'first', 'x', 'b', 'right', 'second', 'y', 'rule'};
const _messageNames = {'name', 'compact', 'at', 'return', 'raw'};
const slashDescriptors = <String, SlashDescriptor>{
  'setvar': SlashDescriptor('setvar', {'key', 'name', 'index', 'as'}),
  'getvar': SlashDescriptor('getvar', {'key', 'index'}),
  'addvar': SlashDescriptor('addvar', {'key', 'name'}),
  'incvar': SlashDescriptor('incvar', {}),
  'setglobalvar': SlashDescriptor('setglobalvar', {'key', 'name', 'index', 'as'}),
  'getglobalvar': SlashDescriptor('getglobalvar', {'key', 'index'}),
  'flushvar': SlashDescriptor('flushvar', {}),
  'if': SlashDescriptor('if', {..._conditionNames, 'else'}, splitUnnamed: true),
  'while': SlashDescriptor('while', {..._conditionNames, 'guard'}, splitUnnamed: true),
  'times': SlashDescriptor('times', {'guard'}, splitUnnamed: true, splitCount: 1),
  'run': SlashDescriptor('run', {'args'}, openNamed: true),
  'pass': SlashDescriptor('pass', {}),
  'return': SlashDescriptor('pass', {}),
  'break': SlashDescriptor('break', {}),
  'abort': SlashDescriptor('abort', {'quiet'}),
  'gen': SlashDescriptor('gen', {'trim', 'lock', 'name', 'length', 'as', 'stop'}),
  'genraw': SlashDescriptor('genraw', {'lock', 'instruct', 'stop', 'as', 'system', 'prefill', 'length', 'trim'}),
  'trigger': SlashDescriptor('trigger', {'await'}),
  'send': SlashDescriptor('send', {'compact', 'at', 'name', 'return', 'raw'}, rawQuotes: true),
  'sendas': SlashDescriptor('sendas', _messageNames, rawQuotes: true),
  'sys': SlashDescriptor('sys', _messageNames, rawQuotes: true),
  'nar': SlashDescriptor('sys', _messageNames, rawQuotes: true),
  'comment': SlashDescriptor('comment', {'compact', 'at', 'return', 'raw'}, rawQuotes: true),
  'inject': SlashDescriptor('inject', {'id', 'position', 'depth', 'role', 'scan'}),
  'listinjects': SlashDescriptor('listinjects', {'return'}),
  'flushinject': SlashDescriptor('flushinject', {}),
  'flushinjects': SlashDescriptor('flushinject', {}),
  'echo': SlashDescriptor('echo', {'title', 'severity', 'escapeHtml', 'awaitDismissal', 'raw'}, rawQuotes: true),
  'input': SlashDescriptor('input', {'default', 'rows', 'wide', 'large', 'okButton'}),
  'buttons': SlashDescriptor('buttons', {'labels'}),
  'popup': SlashDescriptor('popup', {'header', 'wide', 'large', 'okButton', 'result', 'scroll'}),
  'setinput': SlashDescriptor('setinput', {}),
  'hide': SlashDescriptor('hide', {'name'}),
  'unhide': SlashDescriptor('unhide', {'name'}),
  'messages': SlashDescriptor('messages', {'names', 'hidden', 'role'}),
  'cut': SlashDescriptor('cut', {'toolcalls'}),
  'del': SlashDescriptor('del', {'toolcalls'}),
  'getchatbook': SlashDescriptor('getchatbook', {'name', 'create'}),
  'findentry': SlashDescriptor('findentry', {'file', 'field'}),
  'createentry': SlashDescriptor('createentry', {'file', 'key'}),
  'setentryfield': SlashDescriptor('setentryfield', {'file', 'uid', 'field'}),
};
