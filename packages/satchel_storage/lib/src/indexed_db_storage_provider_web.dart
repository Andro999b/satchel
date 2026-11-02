import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:satchel_core/satchel_core.dart' show newId;
import 'package:web/web.dart' as web;

import 'storage_exceptions.dart';
import 'storage_provider.dart';

/// [StorageProvider] backed by the browser's IndexedDB. Web only.
///
/// Each provider uses its own database ([databaseName]) with two object
/// stores: `entries` (path + revision, cheap to list) and `blobs` (the
/// encrypted bytes keyed by path). Every conditional write or delete runs as a
/// single read-compare-write transaction, so revision checks also hold across
/// browser tabs sharing the same database.
final class IndexedDbStorageProvider implements StorageProvider {
  IndexedDbStorageProvider({
    required this.id,
    required this.displayName,
    String? databaseName,
  }) : databaseName = databaseName ?? databaseNameFor(id);

  /// Default IndexedDB database name for the provider with [id].
  static String databaseNameFor(String id) => 'satchel_storage.$id';

  static const _schemaVersion = 1;
  static const _entriesStore = 'entries';
  static const _blobsStore = 'blobs';

  @override
  final String id;

  @override
  final String displayName;

  /// Name of the IndexedDB database holding this provider's blobs.
  final String databaseName;

  Future<web.IDBDatabase>? _db;

  @override
  Future<List<StorageEntry>> list() => _transaction(
    path: '',
    stores: const [_entriesStore],
    readWrite: false,
    body: (op) {
      op.request(op.store(_entriesStore).getAll(), (result) {
        op.result = [
          for (final record in (result! as JSArray<_EntryRecord>).toDart)
            StorageEntry(path: record.path, revision: record.revision),
        ];
      });
    },
  );

  @override
  Future<StoredBlob> read(String path) => _transaction(
    path: path,
    stores: const [_entriesStore, _blobsStore],
    readWrite: false,
    body: (op) {
      final key = path.toJS;
      op.request(op.store(_entriesStore).get(key), (entry) {
        if (entry.isUndefinedOrNull) {
          return op.fail(StorageNotFoundException(path));
        }
        final revision = (entry! as _EntryRecord).revision;
        op.request(op.store(_blobsStore).get(key), (bytes) {
          op.result = StoredBlob(
            entry: StorageEntry(path: path, revision: revision),
            bytes: (bytes! as JSUint8Array).toDart,
          );
        });
      });
    },
  );

  @override
  Future<StorageEntry> write(
    String path,
    Uint8List bytes, {
    required String? expectedRevision,
  }) {
    // Copy now: the put happens later, and the caller may reuse its buffer.
    final data = Uint8List.fromList(bytes).toJS;
    final revision = newId();
    return _transaction(
      path: path,
      stores: const [_entriesStore, _blobsStore],
      readWrite: true,
      body: (op) {
        final entries = op.store(_entriesStore);
        op.request(entries.get(path.toJS), (entry) {
          final current = _revisionOf(entry);
          if (current != expectedRevision) {
            return op.fail(
              StorageConflictException(
                path,
                expectedRevision: expectedRevision,
                actualRevision: current,
              ),
            );
          }
          entries.put(_EntryRecord(path: path, revision: revision));
          op.store(_blobsStore).put(data, path.toJS);
          op.result = StorageEntry(path: path, revision: revision);
        });
      },
    );
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) =>
      _transaction<void>(
        path: path,
        stores: const [_entriesStore, _blobsStore],
        readWrite: true,
        body: (op) {
          final key = path.toJS;
          final entries = op.store(_entriesStore);
          op.request(entries.get(key), (entry) {
            final current = _revisionOf(entry);
            if (current == null) {
              return op.fail(StorageNotFoundException(path));
            }
            if (current != expectedRevision) {
              return op.fail(
                StorageConflictException(
                  path,
                  expectedRevision: expectedRevision,
                  actualRevision: current,
                ),
              );
            }
            entries.delete(key);
            op.store(_blobsStore).delete(key);
            op.result = null;
          });
        },
      );

  /// Closes the database connection. The provider reopens it on next use.
  Future<void> close() async {
    final pending = _db;
    _db = null;
    if (pending == null) return;
    try {
      (await pending).close();
    } on StorageException {
      // Opening failed, so there is nothing to close.
    }
  }

  static String? _revisionOf(JSAny? entry) =>
      entry.isUndefinedOrNull ? null : (entry! as _EntryRecord).revision;

  Future<web.IDBDatabase> _database() async {
    var pending = _db;
    if (pending == null) {
      late final Future<web.IDBDatabase> opening;
      opening = _open(
        onClosed: () {
          if (identical(_db, opening)) _db = null;
        },
      );
      _db = pending = opening;
    }
    try {
      return await pending;
    } on StorageException {
      if (identical(_db, pending)) _db = null;
      rethrow;
    }
  }

  Future<web.IDBDatabase> _open({required void Function() onClosed}) {
    final completer = Completer<web.IDBDatabase>();
    final web.IDBOpenDBRequest request;
    try {
      request = web.window.indexedDB.open(databaseName, _schemaVersion);
    } catch (e) {
      return Future.error(
        StorageBackendException('', 'IndexedDB is not available: $e'),
      );
    }
    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      final db = request.result! as web.IDBDatabase;
      if (event.oldVersion < 1) {
        db.createObjectStore(
          _entriesStore,
          web.IDBObjectStoreParameters(keyPath: 'path'.toJS),
        );
        db.createObjectStore(_blobsStore);
      }
    }.toJS;
    request.onsuccess = (web.Event _) {
      final db = request.result! as web.IDBDatabase;
      // Another tab upgrading or deleting the database, or the browser
      // clearing site data, invalidates this connection: release it and
      // reconnect on next use.
      void release(web.Event _) {
        db.close();
        onClosed();
      }

      db.onversionchange = release.toJS;
      db.onclose = release.toJS;
      completer.complete(db);
    }.toJS;
    request.onerror = (web.Event event) {
      event.preventDefault();
      completer.completeError(
        StorageBackendException(
          '',
          'Cannot open IndexedDB database: ${_describe(request.error)}',
        ),
      );
    }.toJS;
    return completer.future;
  }

  Future<T> _transaction<T>({
    required String path,
    required List<String> stores,
    required bool readWrite,
    required void Function(_Operation<T> op) body,
  }) async {
    final db = await _database();
    final web.IDBTransaction transaction;
    try {
      transaction = db.transaction(
        [for (final store in stores) store.toJS].toJS,
        readWrite ? 'readwrite' : 'readonly',
      );
    } catch (e) {
      throw StorageBackendException(path, 'Cannot start transaction: $e');
    }

    final completer = Completer<T>();
    final op = _Operation<T>(path, transaction);
    transaction.oncomplete = (web.Event _) {
      completer.complete(op.result as T);
    }.toJS;
    transaction.onabort = (web.Event _) {
      completer.completeError(
        op.failure ??
            StorageBackendException(
              path,
              'Transaction aborted: ${_describe(transaction.error)}',
            ),
      );
    }.toJS;
    op.guard(() => body(op));
    return completer.future;
  }
}

/// State of one IndexedDB transaction. Request callbacks run synchronously
/// inside IndexedDB events, which keeps the transaction active between the
/// revision check and the write.
final class _Operation<T> {
  _Operation(this.path, this.transaction);

  final String path;
  final web.IDBTransaction transaction;

  /// Value the transaction resolves with once it commits.
  Object? result;

  /// Error the transaction rejects with after [fail] aborted it.
  StorageException? failure;

  web.IDBObjectStore store(String name) => transaction.objectStore(name);

  void request(web.IDBRequest request, void Function(JSAny? result) onResult) {
    request.onsuccess = (web.Event _) {
      guard(() => onResult(request.result));
    }.toJS;
  }

  void fail(StorageException error) {
    if (failure != null) return;
    failure = error;
    try {
      transaction.abort();
    } catch (_) {
      // Already finished; onabort/oncomplete reports the outcome.
    }
  }

  void guard(void Function() action) {
    try {
      action();
    } catch (e) {
      fail(StorageBackendException(path, 'Unexpected error: $e'));
    }
  }
}

extension type _EntryRecord._(JSObject _) implements JSObject {
  external factory _EntryRecord({
    required String path,
    required String revision,
  });

  external String get path;
  external String get revision;
}

String _describe(web.DOMException? error) =>
    error == null ? 'unknown error' : '${error.name}: ${error.message}';
