/// Current vault file format version.
///
/// Bump on any change to the on-disk layout, header or payload schema, and
/// keep decryption support (plus golden test files) for every older version.
const int currentVaultFormatVersion = 1;

/// File name extension of vault files in every storage.
const String vaultFileExtension = '.satchel';

/// Maximum length of a vault name, in UTF-16 code units.
const int maxVaultNameLength = 100;

/// Whether [path] names a vault file: something followed by
/// [vaultFileExtension].
bool isVaultFileName(String path) =>
    path.length > vaultFileExtension.length &&
    path.endsWith(vaultFileExtension);

/// User-facing name of the vault file at [path]: the path without
/// [vaultFileExtension].
String vaultNameFromPath(String path) => isVaultFileName(path)
    ? path.substring(0, path.length - vaultFileExtension.length)
    : path;

/// Why a vault name can't be used as a file name in every storage.
enum VaultNameError {
  empty,
  tooLong,
  surroundingWhitespace,
  leadingDot,
  trailingDot,
  invalidCharacter,
  reservedName,
}

// Invalid in file names on Windows or Android, or a path separator.
final _invalidCharacters = RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]');

// Device names Windows reserves regardless of extension.
final _reservedNames = RegExp(
  r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])$',
  caseSensitive: false,
);

/// Checks that [name] works as a vault file name on every platform, or
/// returns the first problem.
VaultNameError? checkVaultName(String name) {
  if (name.isEmpty) return VaultNameError.empty;
  if (name.length > maxVaultNameLength) return VaultNameError.tooLong;
  if (name.trim() != name) return VaultNameError.surroundingWhitespace;
  if (name.startsWith('.')) return VaultNameError.leadingDot;
  if (name.endsWith('.')) return VaultNameError.trailingDot;
  if (_invalidCharacters.hasMatch(name)) return VaultNameError.invalidCharacter;
  if (_reservedNames.hasMatch(name)) return VaultNameError.reservedName;
  return null;
}

bool isValidVaultName(String name) => checkVaultName(name) == null;

/// Storage path of the vault named [name]. Throws [ArgumentError] if the
/// name is not valid.
String vaultPathForName(String name) {
  final error = checkVaultName(name);
  if (error != null) {
    throw ArgumentError.value(
      name,
      'name',
      'Invalid vault name (${error.name})',
    );
  }
  return '$name$vaultFileExtension';
}
