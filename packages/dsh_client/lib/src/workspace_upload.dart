/// A file published by the Host into the session's current workspace.
/// Unlike a staged attachment, it has no file receipt to pass to a prompt.
class WorkspaceUploadedFile {
  const WorkspaceUploadedFile({required this.name, required this.path, required this.bytes});

  final String name;
  final String path;
  final int bytes;
}

/// Optional carrier support for uploading directly to a session's workspace.
abstract interface class WorkspaceUploadCarrier {
  /// Capability of the current authenticated connection, never a cached Host.
  bool get supportsWorkspaceUpload;

  /// Absolute protocol ceiling; the Host can enforce a smaller live limit.
  int get maxWorkspaceUploadBytes;

  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name});
}
