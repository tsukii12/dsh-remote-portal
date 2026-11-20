// What a few words said over the voice mean: the ones that only keep the
// conversation company (嗯、对、好的 — they should not stop her), the ones that
// stop her (停、等一下), and anything else, which is the person taking the turn.
// Practice from voice agents (火山 RTC, Vapi's acknowledgement phrases, LiveKit's
// false-interruption handling); the word lists are this app's own.

/// How words spoken over the voice are taken.
enum OverWords {
  /// Agreement or a sound: she goes on.
  backchannel,

  /// "Stop": she stops, and nothing is sent.
  stop,

  /// The person takes the turn: she stops, and what they said is the next message.
  speech,
}

const _backchannel = [
  '嗯哼', '嗯', '哦', '噢', '喔', '啊', '呃', '对', '是的', '是', '好的', '好', '行', '明白', '了解', '可以', '没错', //
  'mhm', 'mmhmm', 'uhhuh', 'okay', 'ok', 'yeah', 'yes', 'yep', 'right', 'sure', 'got it', 'gotit', 'i see', 'isee',
];

const _stop = [
  '停', '停下', '停一下', '先停', '先停一下', '等一下', '等等', '等会', '等会儿', '别说了', '不用说了', '打住', '好了好了', //
  'stop', 'wait', 'hold on', 'holdon',
];

final _noise = RegExp(r'[^\p{L}\p{N} ]', unicode: true);

/// [text] (recognized) taken as said over the voice.
OverWords overWords(String text) {
  final plain = text.toLowerCase().replaceAll(_noise, '').trim();
  if (plain.isEmpty) return OverWords.backchannel;
  final tight = plain.replaceAll(' ', '');
  if (_stop.contains(tight) || _stop.contains(plain)) return OverWords.stop;
  // Made only of agreement sounds, in any run: 嗯嗯、对对对、好的好的、ok ok.
  var rest = tight;
  while (rest.isNotEmpty) {
    final word = _backchannel.map((w) => w.replaceAll(' ', '')).where(rest.startsWith).firstOrNull;
    if (word == null) return OverWords.speech;
    rest = rest.substring(word.length);
  }
  return OverWords.backchannel;
}
