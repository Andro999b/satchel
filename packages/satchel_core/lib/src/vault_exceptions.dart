/// Base class for failures to read a vault file. Messages never contain
/// passwords, keys or decrypted content.
sealed class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The data is not a well-formed vault file of a supported layout.
final class VaultFormatException extends VaultException {
  const VaultFormatException(super.message);
}

/// The file was written by a newer version of Satchel.
final class UnsupportedVaultVersionException extends VaultException {
  const UnsupportedVaultVersionException(this.version)
    : super('Unsupported vault format version $version');

  final int version;
}

/// The file needs extra key-derivation inputs (e.g. a key file) that were
/// not provided.
final class MissingKdfInputException extends VaultException {
  MissingKdfInputException(this.missing)
    : super('Missing key derivation inputs: ${missing.join(', ')}');

  /// Ids of the missing inputs.
  final List<String> missing;
}

/// Decryption failed: wrong password or extra inputs, or the file was
/// modified. AES-GCM can't tell these apart.
final class VaultAuthenticationException extends VaultException {
  const VaultAuthenticationException()
    : super('Wrong password, or the file was modified');
}
