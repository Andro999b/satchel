import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:satchel_storage/satchel_storage.dart';

/// A file in [FakeGoogleDrive].
final class FakeDriveFile {
  FakeDriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.parents,
    required this.createdTime,
    Uint8List? bytes,
  }) : bytes = bytes ?? Uint8List(0);

  final String id;
  String name;
  final String mimeType;
  final List<String> parents;
  final String createdTime;
  Uint8List bytes;
  int version = 1;
  bool trashed = false;

  bool get isFolder => mimeType == driveFolderMimeType;

  String get md5Checksum => md5.convert(bytes).toString();

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'version': '$version',
    if (!isFolder) 'md5Checksum': md5Checksum,
    'createdTime': createdTime,
    'trashed': trashed,
  };
}

/// In-memory Google Drive v3 REST API (the parts Satchel uses), served
/// through [client].
final class FakeGoogleDrive {
  final files = <String, FakeDriveFile>{};
  final requests = <http.Request>[];

  /// Only requests with this bearer token are accepted.
  String validToken = 'token';

  /// Page size of list responses, regardless of what the client asks for.
  int pageSize = 1000;

  /// Answers a request instead of the fake, when it returns a response.
  http.Response? Function(http.Request request)? intercept;

  /// Called after a download is served, e.g. to change the file meanwhile.
  void Function(FakeDriveFile file)? onDownload;

  var _ids = 0;

  late final http.Client client = MockClient(_handle);

  String _newId() => 'id${++_ids}';

  String _time() =>
      DateTime.utc(2026).add(Duration(seconds: _ids)).toIso8601String();

  FakeDriveFile addFolder(String name, {String parent = driveRootFolderId}) {
    final id = _newId();
    return files[id] = FakeDriveFile(
      id: id,
      name: name,
      mimeType: driveFolderMimeType,
      parents: [parent],
      createdTime: _time(),
    );
  }

  FakeDriveFile addFile(
    String name, {
    required String parent,
    List<int> bytes = const [],
  }) {
    final id = _newId();
    return files[id] = FakeDriveFile(
      id: id,
      name: name,
      mimeType: 'application/octet-stream',
      parents: [parent],
      createdTime: _time(),
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// Files (not folders, not trashed) in [folderId].
  List<FakeDriveFile> filesIn(String folderId) => [
    for (final file in files.values)
      if (!file.isFolder && !file.trashed && file.parents.contains(folderId))
        file,
  ];

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    if (intercept?.call(request) case final response?) return response;
    if (request.headers['Authorization'] != 'Bearer $validToken') {
      return _error(401, 'Invalid Credentials');
    }
    final segments = request.url.pathSegments;
    final query = request.url.queryParameters;
    final upload = segments.first == 'upload';
    final rest = upload ? segments.skip(1).toList() : segments;
    if (rest.length < 3 || rest[0] != 'drive' || rest[1] != 'v3') {
      return _error(400, 'Bad path');
    }
    final id = rest.length > 3 ? rest[3] : null;

    switch ((request.method, upload, id)) {
      case ('GET', false, null):
        return _list(query);
      case ('GET', false, final id?):
        final file = files[id];
        if (file == null) return _notFound(id);
        if (query['alt'] == 'media') {
          final bytes = Uint8List.fromList(file.bytes);
          onDownload?.call(file);
          return http.Response.bytes(bytes, 200);
        }
        return _json(file.toJson());
      case ('POST', false, null):
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final id = _newId();
        final file = files[id] = FakeDriveFile(
          id: id,
          name: body['name']! as String,
          mimeType: body['mimeType']! as String,
          parents: [...(body['parents']! as List<Object?>).cast<String>()],
          createdTime: _time(),
        );
        return _json(file.toJson());
      case ('PATCH', false, final id?):
        final file = files[id];
        if (file == null) return _notFound(id);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        if (body['trashed'] == true) file.trashed = true;
        file.version++;
        return _json(file.toJson());
      case ('POST', true, null):
        if (query['uploadType'] != 'multipart') return _error(400, 'type');
        final (metadata, bytes) = _parseMultipart(request);
        final id = _newId();
        final file = files[id] = FakeDriveFile(
          id: id,
          name: metadata['name']! as String,
          mimeType: metadata['mimeType']! as String,
          parents: [...(metadata['parents']! as List<Object?>).cast<String>()],
          createdTime: _time(),
          bytes: bytes,
        );
        return _json(file.toJson());
      case ('PATCH', true, final id?):
        if (query['uploadType'] != 'media') return _error(400, 'type');
        final file = files[id];
        if (file == null) return _notFound(id);
        file
          ..bytes = Uint8List.fromList(request.bodyBytes)
          ..version += 1;
        return _json(file.toJson());
    }
    return _error(400, 'Unsupported request');
  }

  http.Response _list(Map<String, String> query) {
    final conditions = _splitQuery(query['q'] ?? '');
    final matches = [
      for (final file in files.values)
        if (conditions.every((matches) => matches(file))) file,
    ];
    if (query['orderBy'] == 'createdTime') {
      matches.sort((a, b) => a.createdTime.compareTo(b.createdTime));
    }
    final start = int.parse(query['pageToken'] ?? '0');
    final end = (start + pageSize).clamp(0, matches.length);
    return _json({
      'files': [for (final file in matches.sublist(start, end)) file.toJson()],
      if (end < matches.length) 'nextPageToken': '$end',
    });
  }

  /// Parses the Drive query syntax Satchel uses: `and`-joined conditions on
  /// parents, trashed, mimeType and name.
  List<bool Function(FakeDriveFile)> _splitQuery(String q) {
    final parts = <String>[];
    var current = StringBuffer();
    var quoted = false;
    for (var i = 0; i < q.length; i++) {
      final c = q[i];
      if (c == r'\' && quoted) {
        current.write(q.substring(i, i + 2));
        i++;
        continue;
      }
      if (c == "'") quoted = !quoted;
      if (!quoted && q.startsWith(' and ', i)) {
        parts.add(current.toString());
        current = StringBuffer();
        i += 4;
        continue;
      }
      current.write(c);
    }
    if (current.isNotEmpty) parts.add(current.toString());

    String unquote(String value) => value
        .substring(1, value.length - 1)
        .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
    final conditions = <bool Function(FakeDriveFile)>[];
    for (final part in parts) {
      if (RegExp(r"^('.*') in parents$").firstMatch(part) case final m?) {
        final parent = unquote(m[1]!);
        conditions.add((f) => f.parents.contains(parent));
      } else if (part == 'trashed = false') {
        conditions.add((f) => !f.trashed);
      } else if (RegExp(r"^mimeType (!?=) ('.*')$").firstMatch(part)
          case final m?) {
        final type = unquote(m[2]!);
        final equal = m[1] == '=';
        conditions.add((f) => (f.mimeType == type) == equal);
      } else if (RegExp(r"^name = ('.*')$").firstMatch(part) case final m?) {
        final name = unquote(m[1]!);
        conditions.add((f) => f.name == name);
      } else {
        throw ArgumentError.value(part, 'q', 'Unsupported condition');
      }
    }
    return conditions;
  }

  static (Map<String, Object?>, Uint8List) _parseMultipart(
    http.Request request,
  ) {
    final contentType = request.headers['Content-Type']!;
    final boundary = RegExp('boundary=(.+)').firstMatch(contentType)![1]!;
    final body = request.bodyBytes;
    final delimiter = utf8.encode('--$boundary');
    final parts = <Uint8List>[];
    var start = _indexOf(body, delimiter, 0) + delimiter.length;
    while (true) {
      final next = _indexOf(body, delimiter, start);
      if (next < 0) break;
      parts.add(Uint8List.sublistView(body, start, next));
      start = next + delimiter.length;
    }
    Uint8List content(Uint8List part) {
      final headerEnd = _indexOf(part, utf8.encode('\r\n\r\n'), 0) + 4;
      // Drop the CRLF before the next delimiter.
      return Uint8List.sublistView(part, headerEnd, part.length - 2);
    }

    final metadata =
        jsonDecode(utf8.decode(content(parts[0]))) as Map<String, Object?>;
    return (metadata, Uint8List.fromList(content(parts[1])));
  }

  static int _indexOf(List<int> haystack, List<int> needle, int from) {
    outer:
    for (var i = from; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static http.Response _json(Object? json) => http.Response(
    jsonEncode(json),
    200,
    headers: {'content-type': 'application/json'},
  );

  static http.Response _notFound(String id) =>
      _error(404, 'File not found: $id.');

  static http.Response _error(int code, String message) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': message},
    }),
    code,
    headers: {'content-type': 'application/json'},
  );
}

/// [GoogleAuth] handing out [token]; [invalidateToken] switches to [next].
final class FakeTokenAuth implements GoogleAuth {
  FakeTokenAuth({this.token = 'token'});

  String token;
  String? next;
  Object? error;
  final interactiveCalls = <bool>[];

  @override
  Future<String> accessToken(
    GoogleAccount account, {
    bool interactive = false,
  }) async {
    interactiveCalls.add(interactive);
    if (error case final error?) throw error;
    return token;
  }

  @override
  Future<void> invalidateToken(
    GoogleAccount account,
    String accessToken,
  ) async {
    if (accessToken == token && next != null) token = next!;
  }

  @override
  Future<GoogleAccount?> signIn() async => null;

  @override
  void cancelSignIn() {}

  @override
  Future<void> signOut(GoogleAccount account) async {}
}
