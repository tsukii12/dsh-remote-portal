// A word handed to the chat composer (技能 › 「在对话里用」). The Host
// only loads a skill from a whitespace-bounded `/name`, so the insert keeps
// that boundary wherever the caret is.

import 'package:dsh_app/state/composer_insert.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _at(String text, int caret) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret),
);

void _expect(TextEditingValue value, String text, int caret) {
  expect(value.text, text);
  expect(value.selection, TextSelection.collapsed(offset: caret));
  expect(value.composing, TextRange.empty);
}

void main() {
  group('insertComposerToken', () {
    test('an empty composer gets the word and a space', () {
      _expect(insertComposerToken(TextEditingValue.empty, '/pdf'), '/pdf ', 5);
    });

    test('after a word: a space before it', () {
      _expect(insertComposerToken(_at('看看这个', 4), '/pdf'), '看看这个 /pdf ', 10);
    });

    test('before a space: none added after, the caret steps over it', () {
      _expect(insertComposerToken(_at('hello world', 5), '/pdf'), 'hello /pdf world', 11);
    });

    test('after a space, before a word: a space after it only', () {
      _expect(insertComposerToken(_at('hello world', 6), '/pdf'), 'hello /pdf world', 11);
    });

    test('at the start of the text', () {
      _expect(insertComposerToken(_at('总结一下', 0), '/pdf'), '/pdf 总结一下', 5);
    });

    test('after a line break: no space before it', () {
      _expect(insertComposerToken(_at('第一行\n', 4), '/pdf'), '第一行\n/pdf ', 9);
    });

    test('an ideographic space counts as a boundary', () {
      _expect(insertComposerToken(_at('你好　', 3), '/pdf'), '你好　/pdf ', 8);
    });

    test('no caret (never focused): at the end', () {
      const value = TextEditingValue(text: 'abc');
      expect(value.selection.isValid, isFalse);
      _expect(insertComposerToken(value, '/pdf'), 'abc /pdf ', 9);
    });

    test('a selected range is kept; the word goes after it', () {
      const value = TextEditingValue(text: 'abc def', selection: TextSelection(baseOffset: 3, extentOffset: 0));
      _expect(insertComposerToken(value, '/pdf'), 'abc /pdf def', 9);
    });

    test('already there as a word: nothing added, the caret goes after it', () {
      _expect(insertComposerToken(_at('用 /pdf 看看', 0), '/pdf'), '用 /pdf 看看', 7);
      _expect(insertComposerToken(_at('总结 /pdf', 0), '/pdf'), '总结 /pdf', 7);
    });

    test('a longer name that starts the same is another word', () {
      _expect(insertComposerToken(_at('/pdfx', 5), '/pdf'), '/pdfx /pdf ', 11);
      _expect(insertComposerToken(_at('a/pdf', 5), '/pdf'), 'a/pdf /pdf ', 11);
    });

    test('a composing region is dropped', () {
      const value = TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      _expect(insertComposerToken(value, '/pdf'), 'ni /pdf ', 8);
    });
  });

  group('ComposerInsert', () {
    test('a skill is its slash word', () {
      final insert = ComposerInsert.skill('code-review', sessionId: 's1');
      expect(insert.token, '/code-review');
      expect(insert.skill, 'code-review');
      expect(insert.sessionId, 's1');
      expect(insert, ComposerInsert.skill('code-review', sessionId: 's1'));
      expect(insert, isNot(ComposerInsert.skill('code-review', sessionId: null)));
    });

    test('the controller hands a request over once', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <ComposerInsert?>[];
      container.listen(composerInsertProvider, (_, next) => seen.add(next));
      final controller = container.read(composerInsertProvider.notifier);
      expect(controller.take(), isNull);

      final insert = ComposerInsert.skill('pdf', sessionId: null);
      controller.request(insert);
      expect(container.read(composerInsertProvider), insert);
      expect(controller.take(), insert);
      expect(controller.take(), isNull);
      expect(seen, [insert, null]);
    });
  });
}
