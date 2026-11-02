import 'directory_backend.dart';

/// Directory storage needs a filesystem; unavailable on web.
DirectoryBackend directoryBackendFor(String location) =>
    throw UnsupportedError('Directory storage is not available on web');

/// Directory storage needs a filesystem; unavailable on web.
DirectoryPicker createPlatformDirectoryPicker() =>
    throw UnsupportedError('Directory storage is not available on web');
