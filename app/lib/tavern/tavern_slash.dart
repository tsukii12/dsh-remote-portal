// Slash commands in the composer (docs/design/roleplay-roadmap.md P2, 斜杠命令):
// the few of SillyTavern's that map onto what the engine already does. A line
// that is no known command goes as written.

enum TavernSlash {
  /// `/sys`, `/nar`, `/narrate` and words: into the story as narration, no reply.
  narrate('sys', true),

  /// `/send` and words: into the story as yours, no reply.
  sendOnly('send', true),

  /// /continue, /cont: the last reply goes on.
  continueReply('continue', false),

  /// /regen, /regenerate: the last reply written again.
  regenerate('regen', false),

  /// /imp, /impersonate: the model writes your next line into the box.
  impersonate('imp', false);

  const TavernSlash(this.word, this.takesText);

  /// How it is typed (the short form the composer offers).
  final String word;

  /// It needs words after it.
  final bool takesText;
}

const _aliases = {
  'sys': TavernSlash.narrate,
  'nar': TavernSlash.narrate,
  'narrate': TavernSlash.narrate,
  'send': TavernSlash.sendOnly,
  'continue': TavernSlash.continueReply,
  'cont': TavernSlash.continueReply,
  'regen': TavernSlash.regenerate,
  'regenerate': TavernSlash.regenerate,
  'imp': TavernSlash.impersonate,
  'impersonate': TavernSlash.impersonate,
};

/// [text] as a slash command and the words after it; null for an ordinary
/// line (no slash, an unknown word, or a command without its words).
({TavernSlash command, String rest})? tavernSlashOf(String text) {
  final m = RegExp(r'^/([A-Za-z]+)(?:[ \t\n]+([\s\S]*))?$').firstMatch(text.trim());
  if (m == null) return null;
  final command = _aliases[m[1]!.toLowerCase()];
  if (command == null) return null;
  final rest = (m[2] ?? '').trim();
  if (command.takesText && rest.isEmpty) return null;
  if (!command.takesText && rest.isNotEmpty) return null;
  return (command: command, rest: rest);
}
