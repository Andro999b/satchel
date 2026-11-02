import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../storage_exceptions.dart';
import 'google_account.dart';
import 'google_auth.dart';

/// Id of the user's "My Drive" folder.
const driveRootFolderId = 'root';

/// MIME type of Drive folders.
const driveFolderMimeType = 'application/vnd.google-apps.folder';

/// Metadata of a Drive file or folder.
@immutable
final class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    this.md5Checksum = '',
    this.createdTime = '',
  });

  factory DriveFile._fromJson(Map<String, Object?> json) {
    if (json case {'id': final String id, 'name': final String name}) {
      final md5Checksum = json['md5Checksum'];
      final createdTime = json['createdTime'];
      return DriveFile(
        id: id,
        name: name,
        md5Checksum: md5Checksum is String ? md5Checksum : '',
        createdTime: createdTime is String ? createdTime : '',
      );
    }
    throw const StorageBackendException('', 'Unexpected Drive response');
  }

  final String id;
  final String name;

  /// Lowercase hex MD5 of the content (empty for folders). Unlike Drive's
  /// `version`, which also rises on changes invisible to the user, it only
  /// changes with the content.
  final String md5Checksum;

  /// RFC 3339 creation time, used to order files that share a name.
  final String createdTime;

  @override
  bool operator ==(Object other) =>
      other is DriveFile &&
      other.id == id &&
      other.name == name &&
      other.md5Checksum == md5Checksum &&
      other.createdTime == createdTime;

  @override
  int get hashCode => Object.hash(id, name, md5Checksum, createdTime);

  @override
  String toString() => 'DriveFile($id, $name, $md5Checksum)';
}

/// Drive access tokens of one Google account.
///
/// Asks the user to sign in again when needed ([GoogleAuth.accessToken] with
/// `interactive`), so call Drive only from user actions. Fails with
/// [StorageAuthRequiredException] when there is no account, no sign-in for
/// this platform, or the user doesn't sign in.
final class GoogleDriveTokens {
  GoogleDriveTokens({required this.auth, required this.account});

  final GoogleAuth? auth;
  final GoogleAccount? account;

  Future<String>? _pending;

  Future<String> token() => _pending ??= _token().whenComplete(() {
    _pending = null;
  });

  Future<String> _token() async {
    final auth = this.auth;
    final account = this.account;
    if (auth == null || account == null) {
      throw StorageAuthRequiredException('', accountId: account?.id);
    }
    try {
      return await auth.accessToken(account, interactive: true);
    } on GoogleAuthFailedException catch (e) {
      throw StorageBackendException('', e.message);
    } on GoogleAuthException {
      throw StorageAuthRequiredException('', accountId: account.id);
    }
  }

  /// Drops [token] after Drive rejected it.
  Future<void> invalidate(String token) async {
    if ((auth, account) case (final auth?, final account?)) {
      await auth.invalidateToken(account, token);
    }
  }
}

/// The parts of the Drive v3 REST API Satchel uses. Failures are
/// [StorageException]s; a missing file is `null` or
/// [StorageNotFoundException].
final class GoogleDriveApi {
  GoogleDriveApi(this._tokens, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static const _host = 'www.googleapis.com';
  static const _fileFields = 'id,name,md5Checksum,createdTime';

  final GoogleDriveTokens _tokens;
  final http.Client _http;

  /// Files (not folders) directly in [folderId], oldest first.
  Future<List<DriveFile>> listFiles(String folderId, {String? name}) => _list([
    "'${_quote(folderId)}' in parents",
    'trashed = false',
    "mimeType != '$driveFolderMimeType'",
    if (name != null) "name = '${_quote(name)}'",
  ]);

  /// Folders directly in [parentId], sorted by name.
  Future<List<DriveFolder>> listFolders(String parentId) async {
    final folders = await _list([
      "'${_quote(parentId)}' in parents",
      'trashed = false',
      "mimeType = '$driveFolderMimeType'",
    ]);
    return [
      for (final folder in folders)
        DriveFolder(id: folder.id, name: folder.name),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Metadata of [id], or `null` if it doesn't exist or is in the trash.
  Future<DriveFile?> file(String id) async {
    final response = await _send(
      'GET',
      _files('/drive/v3/files/$id', {'fields': '$_fileFields,trashed'}),
      allowNotFound: true,
    );
    if (response == null) return null;
    final json = _json(response);
    if (json['trashed'] == true) return null;
    return DriveFile._fromJson(json);
  }

  /// Content of file [id]. Throws [StorageNotFoundException] if it's gone.
  Future<Uint8List> download(String id, {String path = ''}) async {
    final response = await _send(
      'GET',
      _files('/drive/v3/files/$id', {'alt': 'media'}),
      allowNotFound: true,
      path: path,
    );
    if (response == null) throw StorageNotFoundException(path);
    return response.bodyBytes;
  }

  /// Creates file [name] with [bytes] in [folderId].
  Future<DriveFile> create(
    String folderId,
    String name,
    Uint8List bytes, {
    String path = '',
  }) async {
    final boundary = 'satchel-${_boundaryRandom()}';
    final metadata = utf8.encode(
      jsonEncode({
        'name': name,
        'parents': [folderId],
        'mimeType': 'application/octet-stream',
      }),
    );
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n',
        ),
      )
      ..add(metadata)
      ..add(
        utf8.encode(
          '\r\n--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    final response = await _send(
      'POST',
      _files('/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': _fileFields,
      }),
      body: body.takeBytes(),
      contentType: 'multipart/related; boundary=$boundary',
      path: path,
    );
    return DriveFile._fromJson(_json(response!));
  }

  /// Replaces the content of file [id].
  Future<DriveFile> update(
    String id,
    Uint8List bytes, {
    String path = '',
  }) async {
    final response = await _send(
      'PATCH',
      _files('/upload/drive/v3/files/$id', {
        'uploadType': 'media',
        'fields': _fileFields,
      }),
      body: bytes,
      contentType: 'application/octet-stream',
      allowNotFound: true,
      path: path,
    );
    if (response == null) throw StorageNotFoundException(path);
    return DriveFile._fromJson(_json(response));
  }

  /// Moves file [id] to the trash, where the user can still restore it.
  Future<void> trash(String id, {String path = ''}) async {
    final response = await _send(
      'PATCH',
      _files('/drive/v3/files/$id', {'fields': 'id'}),
      body: utf8.encode(jsonEncode({'trashed': true})),
      contentType: 'application/json; charset=UTF-8',
      allowNotFound: true,
      path: path,
    );
    if (response == null) throw StorageNotFoundException(path);
  }

  /// Creates a folder named [name] in [parentId].
  Future<DriveFolder> createFolder(String parentId, String name) async {
    final response = await _send(
      'POST',
      _files('/drive/v3/files', {'fields': 'id,name'}),
      body: utf8.encode(
        jsonEncode({
          'name': name,
          'mimeType': driveFolderMimeType,
          'parents': [parentId],
        }),
      ),
      contentType: 'application/json; charset=UTF-8',
    );
    final file = DriveFile._fromJson(_json(response!));
    return DriveFolder(id: file.id, name: file.name);
  }

  Future<List<DriveFile>> _list(List<String> query) async {
    final files = <DriveFile>[];
    String? pageToken;
    do {
      final response = await _send(
        'GET',
        _files('/drive/v3/files', {
          'q': query.join(' and '),
          'fields': 'nextPageToken,files($_fileFields)',
          'spaces': 'drive',
          'orderBy': 'createdTime',
          'pageSize': '1000',
          'pageToken': ?pageToken,
        }),
      );
      final json = _json(response!);
      final page = json['files'];
      if (page is! List<Object?>) {
        throw const StorageBackendException('', 'Unexpected Drive response');
      }
      for (final file in page) {
        if (file is! Map<String, Object?>) {
          throw const StorageBackendException('', 'Unexpected Drive response');
        }
        files.add(DriveFile._fromJson(file));
      }
      final next = json['nextPageToken'];
      pageToken = next is String && next.isNotEmpty ? next : null;
    } while (pageToken != null);
    return files;
  }

  /// Sends a request with a fresh access token, retrying once with a new
  /// token if Drive rejects it. Returns `null` for 404 if [allowNotFound].
  Future<http.Response?> _send(
    String method,
    Uri url, {
    List<int>? body,
    String? contentType,
    bool allowNotFound = false,
    String path = '',
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = await _tokens.token();
      final request = http.Request(method, url)
        ..headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.bodyBytes = body;
        if (contentType != null) request.headers['Content-Type'] = contentType;
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request));
      } on Exception {
        throw StorageBackendException(path, 'Could not reach Google Drive');
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) return response;
      if (status == 401) {
        await _tokens.invalidate(token);
        if (attempt == 0) continue;
        throw StorageAuthRequiredException(
          path,
          accountId: _tokens.account?.id,
        );
      }
      if (status == 404 && allowNotFound) return null;
      throw StorageBackendException(path, _errorMessage(response));
    }
  }

  static Uri _files(String path, Map<String, String> query) =>
      Uri.https(_host, path, query);

  static Map<String, Object?> _json(http.Response response) {
    try {
      if (jsonDecode(response.body) case final Map<String, Object?> json) {
        return json;
      }
    } on FormatException {
      // Reported below.
    }
    throw const StorageBackendException('', 'Unexpected Drive response');
  }

  /// Drive's error message, e.g. "The user's Drive storage quota has been
  /// exceeded.", or the status code.
  static String _errorMessage(http.Response response) {
    try {
      if (jsonDecode(response.body) case {
        'error': {'message': final String message},
      }) {
        return message;
      }
    } on FormatException {
      // Fall back to the status.
    }
    return 'Google Drive error ${response.statusCode}';
  }

  /// Escapes a value for a single-quoted string in a Drive query.
  static String _quote(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  static final _random = Random.secure();

  static String _boundaryRandom() =>
      [for (var i = 0; i < 16; i++) _random.nextInt(16).toRadixString(16)]
          .join();
}

/// A Drive folder.
@immutable
final class DriveFolder {
  const DriveFolder({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DriveFolder && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'DriveFolder($id, $name)';
}

/// Browses and creates the Drive folders Satchel can see. With the
/// `drive.file` scope these are only folders Satchel created (on any device).
abstract interface class DriveFolderSource {
  /// Folders in [parentId] ([driveRootFolderId] for "My Drive").
  Future<List<DriveFolder>> list(String parentId);

  Future<DriveFolder> create(String parentId, String name);
}

/// [DriveFolderSource] backed by [GoogleDriveApi].
final class GoogleDriveFolderSource implements DriveFolderSource {
  GoogleDriveFolderSource(this._api);

  final GoogleDriveApi _api;

  @override
  Future<List<DriveFolder>> list(String parentId) => _api.listFolders(parentId);

  @override
  Future<DriveFolder> create(String parentId, String name) =>
      _api.createFolder(parentId, name);
}
