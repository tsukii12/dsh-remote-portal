final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// Strips ANSI escape sequences (DSH and node colour their output).
String stripAnsi(String line) => line.replaceAll(_ansi, '');
