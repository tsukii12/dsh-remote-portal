import 'package:dsh_app/speech/call/turn_words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agreement sounds, alone or in a run, let her go on', () {
    for (final said in ['嗯', '嗯嗯。', '对对对', '好的，好的', '是的', 'OK', 'ok ok', 'Got it.', '', '…']) {
      expect(overWords(said), OverWords.backchannel, reason: said);
    }
  });

  test('stop words stop her without sending anything', () {
    for (final said in ['停', '等一下！', '别说了', 'Stop.', 'hold on']) {
      expect(overWords(said), OverWords.stop, reason: said);
    }
  });

  test('anything else is the person taking the turn', () {
    for (final said in ['对，但是明天下雨怎么办', '好的那换成周六', '停车场在哪', '嗯我想改一下', 'wait for me']) {
      expect(overWords(said), OverWords.speech, reason: said);
    }
  });
}
