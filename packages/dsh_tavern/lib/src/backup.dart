/// Metadata of the immutable source snapshot in a Tavern backup.
///
/// Restoring an older snapshot may migrate its database. [sqliteUserVersion]
/// still describes the source, rather than the migrated destination database.
final class TavernBackupInfo {
  const TavernBackupInfo({
    required this.createdAt,
    required this.sqliteUserVersion,
    required this.fileCount,
    required this.totalBytes,
  });

  final DateTime createdAt;
  final int sqliteUserVersion;
  final int fileCount;

  /// Uncompressed bytes of regular payload files, excluding the manifest.
  final int totalBytes;
}
