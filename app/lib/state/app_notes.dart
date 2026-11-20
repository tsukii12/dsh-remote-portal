// Notes the app writes into a message for the model alone: a voice call's
// "this is a call" and where a cut-in landed, her persona for a host without
// her preset. DSH has no field for words the model reads but the person never
// said, so the notes ride in the message inside <dsh-note> and every place
// that shows a sent message leaves them out.

const _open = '<dsh-note>';
final _notes = RegExp(r'<dsh-note>[\s\S]*?</dsh-note>\n?');
final _leading = RegExp(r'^(?:<dsh-note>[\s\S]*?</dsh-note>\n?)+');

/// [note], for the model only. A closing tag inside it (a persona can say
/// anything) is written `<\/dsh-note>`, so the note ends where it should.
String appNote(String note) => '$_open${note.replaceAll('</dsh-note>', r'<\/dsh-note>')}</dsh-note>';

/// [text] as the person said it: the app's notes left out.
String withoutAppNotes(String text) => text.contains(_open) ? text.replaceAll(_notes, '') : text;

/// [edited] (shown without notes) with the notes [original] began with, so an
/// edited resend still carries them.
String withAppNotesOf(String original, String edited) => '${_leading.firstMatch(original)?[0] ?? ''}$edited';
