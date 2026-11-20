// Agent preset compositions as the editor reads and writes them, against the
// documents a DSH 0.2.1-rc.2 Host returns from `agentPresets/read`
// (fixtures/preset_*.yaml): rows, official names, the persona prompt, the
// rendered list and the bundle files.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/features/preset_editor/preset_composition.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

String _fixture(String id) => File('test/features/fixtures/preset_$id.yaml').readAsStringSync();

/// Reads YAML that carries `!!js` the way the Loader does (as text here).
Object? _load(String yaml) =>
    loadYaml(yaml.replaceAllMapped(RegExp(r'!!js\s+(.*)$', multiLine: true), (m) => jsonEncode('!!js ${m[1]}')));

void main() {
  group('standard', () {
    final standard = PresetComposition.parse(_fixture('standard'));

    test('rows, names and kinds', () {
      expect(standard.rows.map((r) => r.id), [
        'persona',
        'agent-instructions',
        'time-context',
        'tool-bash',
        'tool-pwsh',
        'tool-fs',
        'tool-fs-search',
        'tool-jobs',
        'tool-schedule',
        'skill-filesystem',
        'tool-skill',
        'command-goal',
        'tool-goal',
        'planning',
        'compaction',
        'delegation',
        'tool-ask-user',
        'tool-todo',
        'tool-web',
        'present',
        'tool-plugin-manager',
        'tool-plugin-market',
      ]);
      final byId = {for (final r in standard.rows) r.id: r};
      expect(byId['tool-bash']!.label, 'Bash 命令工具');
      expect(byId['tool-bash']!.condition, "process.platform === 'win32'");
      expect(byId['tool-bash']!.windowsOnly, isFalse);
      expect(byId['tool-pwsh']!.windowsOnly, isTrue);
      expect(byId['planning']!.label, '计划模式');
      expect(byId['delegation']!.children, contains('@deepseek-ai/dsh-tool-subagent'));
      expect(byId['skill-filesystem']!.kind, PresetRowKind.skill);
      expect(byId['tool-web']!.kind, PresetRowKind.tool);
      expect(byId['compaction']!.kind, PresetRowKind.context);
      expect(byId['tool-plugin-manager']!.disabled, isTrue);
      expect(standard.switchable.map((r) => r.id), isNot(contains('persona')));
      expect(standard.switchable.map((r) => r.id), isNot(contains('tool-pwsh')));
      expect(standard.enabled, isNot(contains('tool-plugin-market')));
      expect(standard.prompt, 'You are a coding agent powered by the {{model}} model.');
      expect(standard.completePrompt, isFalse);
    });

    test('rendering unchanged keeps the Host text', () {
      expect(standard.render(enabled: standard.enabled), _fixture('standard').trimRight());
    });

    test('switches and the prompt', () {
      final enabled = {...standard.enabled}
        ..remove('tool-web')
        ..remove('tool-bash')
        ..add('tool-plugin-manager');
      final yaml = standard.render(enabled: enabled, prompt: '你是代码审查员，只读不改。\n逐条列出问题。', complete: true);
      final rows = <Object?, dynamic>{for (final r in _load(yaml)! as List) (r as Map)['id']: r};
      expect(rows['tool-web']['disabled'], isTrue);
      expect(rows['tool-bash']['disabled'], isTrue, reason: 'a !!js switch becomes off');
      expect(rows['tool-plugin-manager'].containsKey('disabled'), isFalse);
      expect(rows['tool-pwsh']['disabled'], "!!js process.platform !== 'win32'", reason: 'untouched');
      expect(rows['persona']['config'], {'prefix': '你是代码审查员，只读不改。\n逐条列出问题。', 'complete': true});
      final again = PresetComposition.parse(yaml);
      expect(again.enabled, enabled);
      expect(again.prompt, '你是代码审查员，只读不改。\n逐条列出问题。');
    });
  });

  test('minimal: a complete persona and a terminal group', () {
    final minimal = PresetComposition.parse(_fixture('minimal'));
    expect(minimal.completePrompt, isTrue);
    expect(minimal.persona['includeRuntimeContext'], isFalse);
    final shell = minimal.rows.firstWhere((r) => r.id == 'persistent-shell');
    expect(shell.label, '持久终端');
    expect(shell.kind, PresetRowKind.tool);
    final yaml = minimal.render(enabled: minimal.enabled, prompt: 'Be brief.');
    expect((_load(yaml)! as List).first['config'], {
      'prefix': 'Be brief.',
      'complete': true,
      'includeRuntimeContext': false,
    });
  });

  test('cordis and ptc parse with every row named', () {
    for (final id in ['cordis', 'ptc']) {
      final c = PresetComposition.parse(_fixture(id));
      for (final r in c.switchable) {
        expect(r.label, isNot(r.id), reason: '$id/${r.id} has an official name');
      }
    }
  });

  group('bundle', () {
    final standard = PresetComposition.parse(_fixture('standard'));
    final bundle = PresetBundle(
      id: 'review',
      name: '代码审查',
      description: '只读审查改动',
      order: 10,
      plugins: standard.render(enabled: {...standard.enabled}..remove('tool-web')),
    );

    test('package.json names the patch', () {
      expect(jsonDecode(bundle.packageJson), {
        'name': '@local/dsh-preset-review',
        'version': '1.0.0',
        'private': true,
        'type': 'module',
        'dsh': {
          'bundle': {'patch': './cordis.patch.yml'},
        },
      });
    });

    test('the patch inserts one declaration row', () {
      final patch = _load(bundle.patch)! as List;
      final insert = (patch.single as Map)['insert'] as List;
      final row = insert.single as Map;
      expect(row['id'], 'preset-review');
      expect(row['name'], '@deepseek-ai/dsh-agent-preset');
      final config = row['config'] as Map;
      expect(config['id'], 'review');
      expect(config['name'], '代码审查');
      expect(config['description'], '只读审查改动');
      expect(config['order'], 10);
      final plugins = config['plugins'] as List;
      expect(plugins.length, standard.rows.length);
      expect((plugins.firstWhere((p) => p['id'] == 'tool-web') as Map)['disabled'], isTrue);
      expect(
        ((plugins.firstWhere((p) => p['id'] == 'planning') as Map)['config'] as List).single['config']['section'],
        startsWith('You are in plan mode.'),
        reason: 'block scalars survive the indent',
      );
    });

    test('the request carries both files verbatim', () {
      final text = bundle.request();
      expect(text, startsWith('新建 Agent 预设「代码审查」（review）：'));
      expect(text, contains('```json\n${bundle.packageJson}\n```'));
      expect(text, contains('```yaml\n${bundle.patch}\n```'));
      expect(bundle.request(replacing: '@local/dsh-preset-review'), contains('先移除组合包 `@local/dsh-preset-review`'));
    });
  });

  test('ids', () {
    expect(presetIdFromName('Code Review!'), 'code-review');
    expect(presetIdFromName('代码审查'), isNull);
    expect(presetIdError('review', {'standard'}), isNull);
    expect(presetIdError('Review', {}), '只用小写字母、数字和连字符');
    expect(presetIdError('standard', {'standard'}), '这个标识已被使用');
    expect(presetIdError('', {}), '填写标识');
  });
}
