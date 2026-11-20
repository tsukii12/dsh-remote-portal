// What leaves the phone in a diagnostics bundle: every line is masked by
// `redactDiagnostics` (launch tokens as the engine log masks them, API-key
// shapes, Bearer credentials, secret-named assignments).

import 'package:dsh_app/diagnostics/redact.dart';
import 'package:flutter_test/flutter_test.dart';

const _sk = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';
final _ghp = 'ghp_${'aB3' * 12}';

void main() {
  group('launch token (as the native log masks it)', () {
    test('query, fragment and bare forms', () {
      expect(
        redactDiagnostics('dsh web: http://127.0.0.1:3080/?token=Zx9.k_~-%2Fq'),
        'dsh web: http://127.0.0.1:3080/?token=•••',
      );
      expect(redactDiagnostics('open http://127.0.0.1:3080/#token=abc123'), 'open http://127.0.0.1:3080/#token=•••');
      expect(redactDiagnostics('[dsh-app] launching dsh web token=abc'), '[dsh-app] launching dsh web token=•••');
    });

    test('an already masked line stays as it is', () {
      const line = 'dsh web: http://127.0.0.1:3080/?token=•••';
      expect(redactDiagnostics(line), line);
    });
  });

  group('API-key shapes are removed whole', () {
    test('a DeepSeek key keeps only its prefix', () {
      final out = redactDiagnostics('[llm] using key $_sk for deepseek');
      expect(out, '[llm] using key sk-••• for deepseek');
      expect(out, isNot(contains('4c1f')));
    });

    test('GitHub, AWS and JWT', () {
      expect(redactDiagnostics('push with $_ghp'), 'push with ghp_•••');
      expect(redactDiagnostics('aws AKIAIOSFODNN7EXAMPLE ok'), 'aws AKIA••• ok');
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      final out = redactDiagnostics('session $jwt end');
      expect(out, isNot(contains('dozjgNryP4J3')));
      expect(out, startsWith('session '));
      expect(out, endsWith(' end'));
    });

    test('a password in a URL', () {
      expect(
        redactDiagnostics('git clone https://bob:s3cret-pass@github.com/o/r.git'),
        'git clone https://bob:•••@github.com/o/r.git',
      );
    });

    test('a private key block keeps its BEGIN and END lines', () {
      const block =
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'b3BlbnNzaC1rZXktdjEAAAAA\n'
          'QyNTUxOQAAACD\n'
          '-----END OPENSSH PRIVATE KEY-----';
      expect(
        redactDiagnostics('key:\n$block\ndone'),
        'key:\n-----BEGIN OPENSSH PRIVATE KEY-----\n•••\n-----END OPENSSH PRIVATE KEY-----\ndone',
      );
    });
  });

  group('secret-named values', () {
    test('environment and JSON assignments', () {
      expect(redactDiagnostics('DEEPSEEK_API_KEY=abcdefgh12345678'), 'DEEPSEEK_API_KEY=•••');
      expect(redactDiagnostics('DEEPSEEK_API_KEY=$_sk'), 'DEEPSEEK_API_KEY=sk-•••');
      expect(redactDiagnostics('{"apiKey": "abcd1234efgh5678"}'), '{"apiKey": "•••"}');
      expect(redactDiagnostics("access_token='q8w7e6r5t4y3'"), "access_token='•••'");
    });

    test('passwords, cookies and authorization of any length', () {
      expect(redactDiagnostics('password=hunter2'), 'password=•••');
      expect(redactDiagnostics('Cookie: dsh_session=s%3Aabc.def; Path=/'), 'Cookie: •••');
      expect(redactDiagnostics('Authorization: Bearer abcdef123456'), 'Authorization: Bearer •••');
      expect(redactDiagnostics('authorization: Basic dXNlcjpwYXNz'), 'authorization: Basic •••');
    });

    test('token counts and ordinary lines stay readable', () {
      for (final line in [
        '[agent] turn finished · 2,431 tokens',
        '[llm] tokens: 1234 in / 56 out',
        'max_tokens=8192',
        '[gateway] listening on 127.0.0.1:3080',
        '[tool] edit: lib/auth/login_controller.dart (+18 −4)',
        'task-runner started',
      ]) {
        expect(redactDiagnostics(line), line, reason: line);
      }
    });
  });

  test('colour escapes are stripped', () {
    expect(redactDiagnostics('\x1B[2m[gateway]\x1B[0m listening'), '[gateway] listening');
  });

  test('a very long line is cut before it is scanned', () {
    final line = 'data:image/png;base64,${'A' * 10000}';
    final out = redactDiagnostics(line);
    expect(out.length, maxLineLength + 1);
    expect(out, endsWith('…'));
  });

  test('redactLines masks each line', () {
    expect(redactLines(['a token=x1', 'b']), ['a token=•••', 'b']);
  });

  test('redactJson masks strings only; keys and other values stay', () {
    expect(
      redactJson({
        'hasApiKey': true,
        'strikes': 2,
        'error': 'login failed for token=abc',
        'recent': ['dsh-x', 'url https://u:pw12345@h/'],
        'nested': {'note': null},
      }),
      {
        'hasApiKey': true,
        'strikes': 2,
        'error': 'login failed for token=•••',
        'recent': ['dsh-x', 'url https://u:•••@h/'],
        'nested': {'note': null},
      },
    );
  });
}
