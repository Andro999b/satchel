/// Base class for storage provider failures.
sealed class StorageException implements Exception {
  const StorageException(this.path);

  final String path;
}

/// The blob at [path] does not exist.
final class StorageNotFoundException extends StorageException {
  const StorageNotFoundException(super.path);

  @override
  String toString() => 'StorageNotFoundException: $path';
}

/// The blob at [path] changed since it was last read (or already exists when
/// creating). Callers resolve this through the merge flow, never by blindly
/// overwriting.
final class StorageConflictException extends StorageException {
  const StorageConflictException(
    super.path, {
    required this.expectedRevision,
    required this.actualRevision,
  });

  final String? expectedRevision;
  final String? actualRevision;

  @override
  String toString() =>
      'StorageConflictException: $path '
      '(expected $expectedRevision, actual $actualRevision)';
}

/// The storage backend failed or is unavailable (e.g. access denied, quota
/// exceeded, storage disabled by the browser). [path] is empty for operations
/// that are not about a single blob, such as listing.
final class StorageBackendException extends StorageException {
  const StorageBackendException(super.path, this.message);

  /// Backend error description. Never contains blob contents.
  final String message;

  @override
  String toString() => 'StorageBackendException: $path: $message';
}

/// The storage needs the user to sign in (again), e.g. to the Google account
/// of a Drive storage. Retrying from a user action signs in.
final class StorageAuthRequiredException extends StorageException {
  const StorageAuthRequiredException(super.path, {this.accountId});

  /// The account to sign in to, if known.
  final String? accountId;

  @override
  String toString() => 'StorageAuthRequiredException: $path ($accountId)';
}
