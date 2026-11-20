import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sample_chat.dart';

void main() {
  group('reply text', () {
    test('a choice is the marker, the title and the visible labels', () {
      final reply = DshUiReply.choice(['方案 A'], title: '选一个方案');
      expect(reply.text, '[dsh-ui reply] 选一个方案\n选择：方案 A');
      expect(reply.chipLabel, '已选择：方案 A');
      expect(DshUiReply.choice(['A', 'C']).text, '[dsh-ui reply]\n选择：A、C');
    });

    test('line breaks in labels and titles are flattened', () {
      final reply = DshUiReply.choice(['第一\n第二 '], title: ' 两行\n标题 ');
      expect(reply.text, '[dsh-ui reply] 两行 标题\n选择：第一 第二');
      expect(parseDshUiReply(reply.text), reply);
    });

    test('a free-text answer rides on its own line', () {
      final both = DshUiReply.choice(['方案 A'], title: '选一个方案', freetext: '先算一次成本');
      expect(both.text, '[dsh-ui reply] 选一个方案\n选择：方案 A\n其他：先算一次成本');
      expect(parseDshUiReply(both.text), both);
      expect(both.chipLabel, '已选择：方案 A · 已填写：先算一次成本');

      final only = DshUiReply.choice(const [], freetext: '都不要，先别动');
      expect(only.text, '[dsh-ui reply]\n其他：都不要，先别动');
      expect(parseDshUiReply(only.text), only);
      expect(only.chipLabel, '已填写：都不要，先别动');
    });

    test('confirm and cancel skip the default words', () {
      expect(DshUiReply.confirm(true, label: '开始').text, '[dsh-ui reply]\n确认：开始');
      expect(DshUiReply.confirm(true, label: '确认').text, '[dsh-ui reply]\n确认');
      expect(DshUiReply.confirm(false, label: '取消').text, '[dsh-ui reply]\n取消');
      expect(DshUiReply.confirm(false, label: '再想想').text, '[dsh-ui reply]\n取消：再想想');
      expect(DshUiReply.confirm(true).chipLabel, '已确认');
      expect(DshUiReply.confirm(true, label: '开始').chipLabel, '已确认：开始');
      expect(DshUiReply.confirm(false).chipLabel, '已取消');
    });
  });

  group('parsing a reply', () {
    test('round-trips what we send', () {
      for (final reply in [
        DshUiReply.choice(['方案 A'], title: '选一个方案'),
        DshUiReply.choice(['A', 'B']),
        DshUiReply.confirm(true, label: '开始', title: '部署'),
        DshUiReply.confirm(false),
      ]) {
        expect(parseDshUiReply(reply.text), reply, reason: reply.text);
      }
    });

    test('takes half-width colons, blank lines and stray spaces', () {
      final reply = parseDshUiReply('  [dsh-ui reply]  标题 \n\n选择: A ');
      expect(reply, const DshUiReply(kind: DshUiReplyKind.choice, title: '标题', value: 'A'));
    });

    test('an unknown body is still a reply', () {
      final reply = parseDshUiReply('[dsh-ui reply] X\n数值：首付=30%');
      expect(reply!.kind, DshUiReplyKind.other);
      expect(reply.chipLabel, '数值：首付=30%');
      expect(parseDshUiReply('[dsh-ui reply]')!.chipLabel, '已回复');
    });

    test('ordinary messages are not replies', () {
      expect(parseDshUiReply('选择：方案 A'), isNull);
      expect(parseDshUiReply('好的 [dsh-ui reply]'), isNull);
      expect(dshUiReplyChip('你好'), isNull);
      expect(dshUiReplyChip('[dsh-ui reply] 计划\n确认'), '已确认');
    });

    test('labels that contain the separator are matched whole', () {
      final reply = DshUiReply.choice(['红、绿', '蓝']);
      expect(reply.selectedIn(['红、绿', '蓝', '黄']), ['红、绿', '蓝']);
      expect(reply.choices, ['红', '绿', '蓝']);
    });
  });

  group('state from the message order (§3.5)', () {
    final view = assistant(2, '看完再选');
    const reply = '[dsh-ui reply] 选一个方案\n选择：方案 A';

    test('the last reply of a finished turn can be answered', () {
      final state = dshUiStateFor(items: [user(1, '帮我比较'), view], messageId: view.id, running: false);
      expect(state, DshUiState.live);
      expect(state.canAnswer, isTrue);
    });

    test('a running turn disables it', () {
      expect(dshUiStateFor(items: [user(1, 'q'), view], messageId: view.id, running: true), DshUiState.running);
      final streaming = assistant(2, '看完再选', streaming: true);
      expect(dshUiStateFor(items: [streaming], messageId: streaming.id, running: false), DshUiState.running);
    });

    test('a reply after it answers it; anything else expires it', () {
      final answered = dshUiStateFor(
        items: [view, user(3, reply), assistant(4, '好的')],
        messageId: view.id,
        running: true,
      );
      expect(answered.interaction, DshUiInteraction.answered);
      expect(answered.reply!.value, '方案 A');
      expect(dshUiStateFor(items: [view, user(3, '换个思路')], messageId: view.id, running: false), DshUiState.expired);
      // Only the first user message after the view counts.
      expect(
        dshUiStateFor(items: [view, user(3, '等等'), user(5, reply)], messageId: view.id, running: false),
        DshUiState.expired,
      );
    });

    test('the model talking on (after a tool call) expires it', () {
      expect(
        dshUiStateFor(
          items: [
            view,
            tool('t1', 'bash', {'command': 'ls'}),
            assistant(4, '我先看一下'),
          ],
          messageId: view.id,
          running: false,
        ),
        DshUiState.expired,
      );
      // An empty assistant step does not.
      expect(dshUiStateFor(items: [view, assistant(4, '  ')], messageId: view.id, running: false), DshUiState.live);
    });

    test('a prompt sent but not yet echoed already counts', () {
      final state = dshUiStateFor(items: [view], messageId: view.id, running: false, pending: [reply]);
      expect(state.interaction, DshUiInteraction.answered);
      expect(dshUiStateFor(items: [view], messageId: view.id, running: false, pending: ['别的']), DshUiState.expired);
    });

    test('an unknown message is read-only', () {
      expect(dshUiStateFor(items: [view], messageId: 'a404', running: false), DshUiState.expired);
    });
  });

  group('which view a reply answers', () {
    DshUiView parse(String json) => (parseDshUiUncached(json) as DshUiParsed).view;

    final titled = parse(
      '{"type":"stack","title":"选一个方案","children":['
      '{"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}]}',
    );

    test('titles must agree when both have one', () {
      final ok = dshUiAnswerFor(titled, DshUiReply.choice(['方案 B'], title: '选一个方案'));
      expect(ok!.selected, ['方案 B']);
      expect(dshUiAnswerFor(titled, DshUiReply.choice(['方案 B'], title: '别的卡')), isNull);
      expect(dshUiAnswerFor(titled, DshUiReply.choice(['方案 B'])), isNotNull);
    });

    test('a confirm reply needs a confirm', () {
      expect(dshUiAnswerFor(titled, DshUiReply.confirm(true)), isNull);
      final confirm = parse('{"type":"confirm","confirmLabel":"开始"}');
      expect(dshUiAnswerFor(confirm, DshUiReply.confirm(true, label: '开始'))!.confirmed, isTrue);
    });

    test('free text only counts on a card that allows it', () {
      final free = parse(
        '{"type":"stack","children":['
        '{"type":"options","id":"plan","freetext":true,"options":[{"label":"方案 A"}]}]}',
      );
      final typed = dshUiAnswerFor(free, DshUiReply.choice(const [], freetext: '再算一次'));
      expect(typed!.selected, isEmpty);
      expect(typed.freetext, '再算一次');
      // 选项和「其他」可以一起答。
      final both = dshUiAnswerFor(free, DshUiReply.choice(['方案 A'], freetext: '先别动'));
      expect(both!.selected, ['方案 A']);
      expect(both.freetext, '先别动');
      // 没开 freetext 的卡不认这句。
      expect(dshUiAnswerFor(titled, DshUiReply.choice(const [], freetext: '再算一次')), isNull);
    });
  });
}
