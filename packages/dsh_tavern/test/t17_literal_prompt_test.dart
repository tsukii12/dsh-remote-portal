import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

const _literal = '【状态】{"value":"{{incvar::must_not_run}}","label":"{{char}}"}';
ChatPreset _preset() =>
    ChatPreset({...ChatPreset.stDefault().raw, 'openai_max_context': 16000, 'openai_max_tokens': 100});
String _bodyText(PromptAssembly value) => (value.body['messages']! as List<Object?>)
    .cast<Map<String, Object?>>()
    .map((message) => message['content'])
    .join('\n');

void main() {
  for (final deepseek in [false, true]) {
    for (final placement in PromptPlacement.values) {
      test('generated state stays literal through $placement and deepseek=$deepseek', () {
        var ordinaryExpansions = 0;
        String expand(String text, Map<String, String> overrides) {
          // Both preparation and the later history pass use this callback.
          if (text.contains('must_not_run')) {
            throw StateError('State text reached the macro engine.');
          }
          if (text.contains('{{ordinary}}')) {
            ordinaryExpansions++;
          }
          return text.replaceAll('{{ordinary}}', 'ordinary-expanded');
        }

        final result = const PromptAssembler().assemble(
          PromptInput(
            preset: _preset(),
            card: const {'name': 'Character'},
            model: 'fixture-model',
            deepseek: deepseek,
            history: const [
              PromptHistoryMessage(id: 'one', role: 'assistant', content: 'earlier'),
              PromptHistoryMessage(id: 'two', role: 'user', content: 'latest'),
            ],
            expansion: expand,
            cardExpansion: expand,
            injections: [
              PromptInjection(
                fragment: const PromptFragment(_literal, PromptSource('state', 'dsh_state'), expandMacros: false),
                placement: placement,
                depth: 1,
              ),
              PromptInjection(
                fragment: const PromptFragment('NOTE {{ordinary}}', PromptSource('note', 'ordinary')),
                placement: placement,
                depth: 1,
              ),
            ],
          ),
        );
        expect(_bodyText(result), contains(_literal));
        expect(_bodyText(result), contains('NOTE ordinary-expanded'));
        expect(ordinaryExpansions, greaterThan(0));
        expect(
          result.beforePostProcessing
              .where((segment) => segment.sources.any((source) => source.kind == 'state'))
              .map((segment) => segment.message['content'])
              .join('\n'),
          contains(_literal),
        );
      });
    }
  }
  test('mixed role pieces keep literal state separate from ordinary macros during continuation', () {
    final seen = <String>[];
    String expand(String text, Map<String, String> overrides) {
      seen.add(text);
      if (text.contains('must_not_run')) {
        throw StateError('Literal piece was expanded.');
      }
      return text.replaceAll('{{ordinary}}', 'expanded');
    }

    final result = const PromptAssembler().assemble(
      PromptInput(
        preset: _preset(),
        card: const {'name': 'Character'},
        model: 'fixture-model',
        deepseek: false,
        generationType: 'continue',
        history: const [PromptHistoryMessage(id: 'one', role: 'assistant', content: 'continue this')],
        expansion: expand,
        cardExpansion: expand,
        injections: const [
          PromptInjection(
            fragment: PromptFragment('aggregate is replaced', PromptSource('state', 'dsh_state')),
            depth: 1,
            fragments: [
              PromptFragment(_literal, PromptSource('state', 'value'), role: 'system', expandMacros: false),
              PromptFragment('NOTE {{ordinary}}', PromptSource('note', 'ordinary'), role: 'user'),
            ],
          ),
        ],
      ),
    );
    expect(_bodyText(result), contains(_literal));
    expect(_bodyText(result), contains('NOTE expanded'));
    expect(_bodyText(result), isNot(contains('aggregate is replaced')));
    expect(seen.any((text) => text.contains('must_not_run')), isFalse);
  });
}
