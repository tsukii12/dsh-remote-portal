import 'dart:async';

import 'package:dsh_app/state/chat_error_text.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = <(Object, String)>[
    (const DshTransportException('raw'), '没能连上引擎'),
    (const DshCarrierLostException('raw'), '没能连上引擎'),
    (const DshClosedException(), '没能连上引擎'),
    (TimeoutException('raw'), '没能连上引擎'),
    (const DshHttpException(500, 'raw'), '没能连上引擎'),
    (const DshHttpException(401, 'raw'), '没能通过引擎的验证'),
    (const DshHttpException(403, 'raw'), '没能通过引擎的验证'),
    (const DshCarrierRefusedException('AUTH', 'raw'), '没能通过引擎的验证'),
    for (final (code, reason) in const [
      ('session/not-found', '这个对话已经不在了'),
      ('session/format-unsupported', '当前引擎无法读取此对话的日志格式，请导出诊断包排查'),
      ('session/agent-busy', 'AI 正忙，稍后再试'),
      ('session/writer-held', '这个对话正在别处使用'),
      ('session/model-unavailable', '这个模型现在用不了'),
      ('session/provider-models-unavailable', '这个模型现在用不了'),
      ('session/attachment-invalid', '这个附件发不了'),
      ('session/fork-unavailable', '这里不能分叉'),
      ('FRAME_TOO_LARGE', '图片太大，少选几张再发'),
      ('gateway/method-not-found', '当前引擎版本不支持'),
    ])
      (DshRemoteException(code, 'Exception(raw): boom'), reason),
    (const DshRemoteException('gateway/internal', 'boom'), ''),
    (const DshRemoteException('x', 'boom'), ''),
    (StateError('Exception(raw): boom'), ''),
  ];
  for (var i = 0; i < cases.length; i++) {
    test('maps display error $i without raw details', () {
      final (error, reason) = cases[i];
      final text = chatErrorText(error, action: '提交失败');
      expect(text, reason.isEmpty ? '提交失败' : '提交失败：$reason');
      for (final raw in ['Exception', '(', ':', 'boom']) {
        expect(text, isNot(contains(raw)));
      }
    });
  }
}
