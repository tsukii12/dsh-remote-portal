part of 'engine.dart';

class _PromptHistoryWindow {
  _PromptHistoryWindow(this.nodes, this.path, this.first, this.identityNode, this.bodyNodes)
    : unreadCount = path.length - nodes.length;
  final List<StoredNode> nodes;
  final List<StoredHistoryLink> path;
  final StoredNode? first;
  final StoredNode? identityNode;
  final int unreadCount;
  int bodyNodes;

  List<PromptHistoryMessage> get prefix => [
    for (final link in path.take(unreadCount))
      PromptHistoryMessage(
        id: link.nodeId,
        role: link.role.name,
        content: '',
        name: link.speaker,
        hidden: link.hidden,
        isSystem: link.isSystem,
      ),
  ];
}

// An unchanged suffix can be bounded before assembly. Dynamic configurations
// keep the original complete history and macro order; no macro is speculated
// or replayed to decide whether a message will fit.
_PromptHistoryWindow? _plainPromptHistory(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  ChatPreset preset,
  String? leaf, {
  required PromptTokenCounter counter,
  required WorldInfoSettings worldSettings,
}) {
  final settings = preset.settings;
  if (engine._counter is! EstimatedTokenCounter ||
      (turn.kind != _TurnKind.send && turn.kind != _TurnKind.regenerate) ||
      turn.groupView != null ||
      engine._scripts.contexts.values.any((context) => !context.closed && context.value.chatId == turn.chat.id) ||
      turn.scriptInjectionUses?.used.isNotEmpty == true ||
      _map(turn.settings['reasoning'])['add_to_prompts'] == true ||
      _hasWorldTimers(turn.state['timedWorldInfo']) ||
      _hasGameplayWorldTimers(turn.state, turn.gameplayResources) ||
      worldSettings.minActivations > 0 ||
      !_literalPromptName(data['name']) ||
      !_literalPromptName(data['nickname']) ||
      !_literalPromptName(turn.settings['userName']) ||
      !_plainPromptData(turn.input) ||
      !_plainPromptData(data) ||
      !_plainPromptData(turn.settings) ||
      !_plainPromptData(settings) ||
      _hasTurnHistoryRules(data, turn.settings, settings, turn.actorId, packRegex: turn.gameplayResources.regex)) {
    return null;
  }
  final budget =
      presetNumber(settings['openai_max_context'], 4095).toInt() -
      presetNumber(settings['openai_max_tokens'], 300).toInt();
  if (budget < 0) return null;
  final path = engine._store.historyLinksTo(turn.chat.id, leaf);
  final reversed = <StoredNode>[];
  var spent = 0;
  var bodyNodes = 0;
  var cursor = leaf;
  while (cursor != null && spent <= budget) {
    final page = engine._store.promptHistoryTo(turn.chat.id, cursor, limit: 32);
    bodyNodes += page.length;
    for (final node in page.reversed) {
      reversed.add(node);
      if (!node.message.hidden && !_systemMessage(node)) {
        if (!_plainPromptText(node.message.text) || !_plainPromptText(node.message.speaker)) return null;
        spent += plainHistoryTokenCost(
          counter,
          _promptHistory(node),
          namesBehavior: settings['names_behavior'],
          userName: turn.settings['userName'] is String ? turn.settings['userName']! as String : 'User',
          group: false,
        );
      }
      // Keep the first overflowing node. Fixed prompts, controls and the new
      // user can only consume more of this budget, never make older text fit.
      if (spent > budget) break;
    }
    cursor = page.first.message.parentId;
  }
  final nodes = reversed.reversed.toList();
  final first = path.isEmpty
      ? null
      : nodes.length == path.length
      ? nodes.first
      : engine._store.promptHistoryTo(turn.chat.id, path.first.nodeId, limit: 1).single;
  if (path.isNotEmpty && nodes.length != path.length) bodyNodes++;
  if (first != null && !_plainPromptText(first.message.text)) return null;
  final identityNode = leaf == null
      ? null
      : engine._store.promptHistoryTo(turn.chat.id, leaf, limit: 1, includeSource: true).single;
  if (identityNode != null) bodyNodes++;
  return _PromptHistoryWindow(nodes, path, first, identityNode, bodyNodes);
}

// Recursion adds admitted entry text, not older messages. Only the separate
// min-activations path widens depth; that path keeps the complete history.
int _worldHistoryDepth(List<WorldInfoBook> books, WorldInfoSettings settings) {
  var depth = 0;
  for (final book in books) {
    for (final entry in book.entries) {
      depth = max(depth, (entry.scanDepth ?? settings.scanDepth).clamp(0, 1000).toInt());
      // Include every finite fallback as an upper bound without selecting a
      // runtime decorator branch or invoking its macros a second time.
      for (final line in worldInfoDecoratorHeader(entry.content)) {
        if (line.name != 'scan_depth') continue;
        final value = num.tryParse(line.value);
        if (value != null && value.isFinite) depth = max(depth, value.clamp(0, 1000).toInt());
      }
    }
  }
  return depth;
}

List<StoredNode> _worldHistoryWindow(
  TavernEngine engine,
  String chatId,
  String? leaf,
  List<StoredNode> promptHistory,
  _PromptHistoryWindow window, {
  required int depth,
  required bool includeNames,
}) {
  if (depth == 0) return [];
  final reversed = <StoredNode>[];
  var complete = false;
  void take(Iterable<StoredNode> nodes) {
    for (final node in nodes) {
      if (node.message.hidden || _systemMessage(node)) continue;
      reversed.add(node);
      // ScanBuffer pads empty slots only when an older nonempty raw message
      // exists. Preserve those separators before trimming, within its 1000 cap.
      if (reversed.length == 1000 || (reversed.length >= depth && (includeNames || node.message.text.isNotEmpty))) {
        complete = true;
        break;
      }
    }
  }

  take(promptHistory.reversed);
  var cursor = promptHistory.isEmpty ? leaf : promptHistory.first.message.parentId;
  while (!complete && cursor != null) {
    final page = engine._store.promptHistoryTo(chatId, cursor, limit: 32);
    window.bodyNodes += page.length;
    take(page.reversed);
    cursor = page.first.message.parentId;
  }
  return reversed.reversed.toList();
}

bool _hasTurnHistoryRules(
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> preset,
  String characterId, {
  List<TavernScriptRegex> packRegex = const [],
}) {
  if (settings['regexEnabled'] == false) return false;
  final scripts = [
    for (final rule in packRegex)
      if (rule.effective) rule.execution,
    ...RegexEngine.readScripts(settings['globalRegexScripts'] ?? settings['regex']),
    ...RegexEngine.readScripts(settings['managedRegexScripts']),
    if (settings['presetRegexEnabled'] != false)
      ...RegexEngine.readScripts(_map(preset['extensions'])['regex_scripts']),
    if (settings['characterRegexEnabled'] != false &&
        !_strings(settings['disabledCharacterRegex']).contains(characterId))
      ...RegexEngine.readScripts(_map(data['extensions'])['regex_scripts']),
  ];
  // WI captures can synthesize a history macro absent from every raw string.
  // Keep its prompt replacements on the complete-history path as well.
  return scripts.any(
    (script) =>
        !script.disabled &&
        (script.promptOnly || !script.markdownOnly) &&
        script.placement.any(
          (placement) =>
              placement == RegexPlacement.userInput ||
              placement == RegexPlacement.aiOutput ||
              placement == RegexPlacement.reasoning ||
              (placement == RegexPlacement.worldInfo && script.promptOnly),
        ),
  );
}

bool _plainPromptData(Object? value) {
  if (value is String) return _plainPromptText(value.replaceAll(_promptNameMacro, ''));
  if (value is List<Object?>) return value.every(_plainPromptData);
  if (value is Map<String, Object?>) return value.values.every(_plainPromptData);
  return true;
}

bool _hasWorldTimers(Object? value) {
  if (value is! Map<String, Object?>) return false;
  for (final key in const ['sticky', 'cooldown']) {
    final timers = value[key];
    if ((timers is Map<String, Object?> && timers.isNotEmpty) || (timers is List<Object?> && timers.isNotEmpty)) {
      return true;
    }
  }
  return false;
}

bool _literalPromptName(Object? value) =>
    value is! String ||
    (_plainPromptText(value) && !value.contains('{') && !value.contains('}') && !value.contains('<'));

// Both dialects recognize brace/angle macros. The modern postprocessor also
// unescapes braces and removes its private ELSE marker without a parsed call.
bool _plainPromptText(String text) {
  final normalized = text.replaceAll('\r', '');
  return !normalized.contains('{{') &&
      !normalized.contains('}}') &&
      !normalized.contains(r'\{') &&
      !normalized.contains(r'\}') &&
      !normalized.contains('\u0000') &&
      !_promptAngleMacro.hasMatch(normalized);
}

final _promptAngleMacro = RegExp(r'<(USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>', caseSensitive: false);
// Normalized presets eagerly prepare name-only controls even on a normal
// send. These macros do not consult history or mutate variables; their literal
// names above cannot introduce a new macro in legacy replacement passes.
final _promptNameMacro = RegExp(
  r'{{\s*(user|char|charIfNotGroup|group|groupNotMuted|notChar)\s*}}',
  caseSensitive: false,
);

bool _hasGameplayWorldTimers(Map<String, Object?> state, _GameplayResources resources) {
  final snapshot = _gameplayWorldInfoSnapshot(state, resources);
  if (snapshot == null) {
    return false;
  }
  for (final source in resources.packSources.values.map((entry) => entry.source).toSet()) {
    final saved = snapshot.read(source);
    if (saved.issues.isNotEmpty) {
      return true;
    }
    final raw = saved.raw;
    if (!saved.exists || raw is! Map<String, Object?>) {
      continue;
    }
    final entries = raw['entries'];
    if (entries is Map<String, Object?>) {
      for (final resource in entries.values) {
        if (resource is Map<String, Object?> &&
            resource.values.any(
              (entry) =>
                  entry is Map<String, Object?> && (entry.containsKey('sticky') || entry.containsKey('cooldown')),
            )) {
          return true;
        }
      }
    }
  }
  return false;
}
