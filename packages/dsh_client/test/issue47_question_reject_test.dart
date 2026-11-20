import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  test('rejectQuestion settles the pending event with the existing rejected outcome', () async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    final client = DshClient(connection);
    addTearDown(() async {
      await client.close();
      await host.close();
    });
    await connection.login(FakeDsh.token);
    Map<String, Object?>? seen;
    host.handlers[r'$events/result'] = (args) {
      seen = args;
      return {'ok': true};
    };
    const request = UserQuestionRequest(eventId: 'q', sessionId: 's', questions: []);
    final cancelled = client.hostEvents.where((e) => e is HostRequestCancelledEvent).first;
    await client.rejectQuestion(request, code: 'ASK_CANCELLED', message: 'The user declined to answer this question.');
    expect((await cancelled as HostRequestCancelledEvent).eventId, 'q');
    expect(seen!['eventId'], 'q');
    expect(seen!['outcome'], {
      'kind': 'rejected',
      'error': {
        'name': 'UserQuestionError',
        'message': 'The user declined to answer this question.',
        'code': 'ASK_CANCELLED',
      },
    });
  });
}
