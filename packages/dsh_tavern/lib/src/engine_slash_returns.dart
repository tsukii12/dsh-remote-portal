// The approved return modes adapt SillyTavern's SlashCommandReturnHelper
// (7e8663cd9c184a550b37238218bdd32c6efc68e9, AGPL-3.0). Rendering remains an
// explicit App responsibility; these sources are never expanded a second time.
part of 'engine.dart';

enum _SlashReturnMode { none, pipe, object, chatHtml, chatText, popupHtml, popupText, toastHtml, toastText }

_SlashReturnMode _slashReturnMode(_SlashInvocation invocation, {required String fallback}) {
  final value = _slashNamed(invocation, 'return', fallback: fallback);
  return switch (value) {
    'none' => _SlashReturnMode.none,
    'pipe' => _SlashReturnMode.pipe,
    'object' => _SlashReturnMode.object,
    'chat-html' => _SlashReturnMode.chatHtml,
    'chat-text' => _SlashReturnMode.chatText,
    'popup-html' => _SlashReturnMode.popupHtml,
    'popup-text' => _SlashReturnMode.popupText,
    'toast-html' => _SlashReturnMode.toastHtml,
    'toast-text' => _SlashReturnMode.toastText,
    _ => throw _slashArgument(
      invocation,
      'return',
      'This return mode is not supported.',
      code: TavernScriptErrorCode.unsupportedOption,
    ),
  };
}

extension _SlashReturnOperations on _ScriptCoordinator {
  Future<String> _returnSlashValue(
    _SlashInvocation invocation,
    _SlashReturnMode mode, {
    required String text,
    required Map<String, Object?> object,
  }) async {
    final owner = invocation.owner;
    owner.checkAlive();
    switch (mode) {
      case _SlashReturnMode.none:
        return '';
      case _SlashReturnMode.pipe:
        return text;
      case _SlashReturnMode.object:
        return jsonEncode(_captureScriptObject(object));
      case _SlashReturnMode.chatHtml:
      case _SlashReturnMode.chatText:
        {
          final html = mode == _SlashReturnMode.chatHtml;
          final admission = await _captureSlashChat(owner);
          owner.checkAlive();
          await _createSlashMessage(
            owner,
            admission,
            insertion: admission.capture.path.length,
            role: TavernRole.system,
            name: 'SillyTavern System',
            text: text,
            extra: {
              'type': 'generic',
              'dshgo_display': {'textKind': html ? 'html' : 'plain', 'renderMarkdown': html},
            },
          );
          owner.checkAlive();
          return '';
        }
      case _SlashReturnMode.popupHtml:
      case _SlashReturnMode.popupText:
        {
          final html = mode == _SlashReturnMode.popupHtml;
          await _interactForExecution(invocation, 'popup', {
            'text': text,
            'textKind': html ? 'html' : 'plain',
            'renderMarkdown': html,
            'wide': true,
            'large': false,
            'scroll': true,
            'okButton': 'OK',
          });
          owner.checkAlive();
          return '';
        }
      case _SlashReturnMode.toastHtml:
      case _SlashReturnMode.toastText:
        {
          final html = mode == _SlashReturnMode.toastHtml;
          await _interactForExecution(invocation, 'echo', {
            'text': text,
            'textKind': html ? 'html' : 'plain',
            'renderMarkdown': html,
            'severity': 'info',
            'awaitDismissal': false,
          });
          owner.checkAlive();
          return '';
        }
    }
  }
}
