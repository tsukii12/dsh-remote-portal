import 'package:dsh_client/dsh_client.dart';

import '../notify/answer_native_request.dart';

/// Answers one native phone card only in the generation that presented it.
Future<bool> answerPhoneApproval({
  required DshClient client,
  required MuxGeneration generation,
  required ApprovalRequest request,
  required ApprovalDecision decision,
  required bool Function() current,
}) async {
  if (decision != ApprovalDecision.allowOnce && decision != ApprovalDecision.reject) {
    return false;
  }
  return answerNativeRequest(
    client: client,
    generation: generation,
    eventId: request.eventId,
    outcome: {'kind': 'result', 'value': decision.wire},
    current: current,
  );
}
