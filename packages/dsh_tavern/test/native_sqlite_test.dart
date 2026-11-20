import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('bundled SQLite loads in pure Dart and provides FTS5', () {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    database.execute('CREATE VIRTUAL TABLE messages USING fts5(body)');
    database.execute('INSERT INTO messages(body) VALUES (?)', ['tavern 中文 🐋']);

    final rows = database.select('SELECT body FROM messages WHERE messages MATCH ?', ['tavern']);
    expect(rows.single['body'], 'tavern 中文 🐋');
  });
}
