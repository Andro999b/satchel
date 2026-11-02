import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'ids.dart';
import 'json_utils.dart';
import 'secret_info.dart';
import 'vault_exceptions.dart';

/// Kinds of secrets. The names are the `type` values in vault files: never
/// rename them.
enum SecretType { password, login, pem, recoveryCodes, note }

/// Where a secret stands relative to its `expiresAt`.
enum ExpiryStatus {
  /// The secret has no expiry.
  none,
  valid,

  /// Expires within the warning period.
  expiringSoon,
  expired,
}

/// An entry in a vault file.
///
/// Every type shares [info] (id, title, tags, timestamps, expiry, notes,
/// custom fields), exposed through getters. Code that handles secrets
/// switches exhaustively on the subtypes, so adding a type forces every
/// view and editor to handle it.
///
/// Secrets are immutable. Edit with the subtype's `copyWith`, then stamp the
/// result with [Secret.applyEdit] so `updatedAt` follows the timestamp rules.
/// [toString] never reveals anything but the type and id.
@immutable
sealed class Secret {
  const Secret(this.info);

  /// Parses [toJson] output. Throws [VaultFormatException] if malformed or of
  /// an unknown type.
  factory Secret.fromJson(Object? json) {
    final map = readObject(json, 'secret');
    final typeName = readField<String>(map, 'type', 'secret');
    final type = SecretType.values.asNameMap()[typeName];
    if (type == null) {
      throw const VaultFormatException('Unknown secret type');
    }
    final info = SecretInfo.fromJson(map);
    String text(String key) => readField<String>(map, key, type.name);
    return switch (type) {
      SecretType.password => PasswordSecret(
        info: info,
        password: text('password'),
      ),
      SecretType.login => LoginSecret(
        info: info,
        username: text('username'),
        password: text('password'),
        url: text('url'),
        totp: text('totp'),
      ),
      SecretType.pem => PemSecret(info: info, pem: text('pem')),
      SecretType.recoveryCodes => RecoveryCodesSecret(
        info: info,
        codes: readList(map, 'codes', type.name, RecoveryCode.fromJson),
      ),
      SecretType.note => NoteSecret(info: info, text: text('text')),
    };
  }

  /// Default warning period for [expiryStatus].
  static const expiryWarning = Duration(days: 30);

  final SecretInfo info;

  SecretType get type;

  String get id => info.id;
  String get title => info.title;
  List<String> get tags => info.tags;
  DateTime get createdAt => info.createdAt;
  DateTime get updatedAt => info.updatedAt;
  DateTime? get expiresAt => info.expiresAt;
  String get notes => info.notes;
  List<CustomField> get customFields => info.customFields;

  /// This secret with [info] replaced. Subtypes return their own type.
  Secret withInfo(SecretInfo info);

  /// The type-specific fields of the JSON.
  Map<String, Object?> _contentJson();

  /// Whether the type-specific fields equal [other]'s, which has the same
  /// runtime type.
  bool _sameTypeContent(covariant Secret other);

  int get _contentHash;

  /// Whether this and [other] hold the same content: same type and equal
  /// fields, ignoring the id and the `createdAt`/`updatedAt` history.
  bool sameContentAs(Secret other) =>
      other.runtimeType == runtimeType &&
      info.sameContentAs(other.info) &&
      _sameTypeContent(other);

  /// [ExpiryStatus] at [now]; [warning] is how early to report
  /// [ExpiryStatus.expiringSoon].
  ExpiryStatus expiryStatus(
    DateTime now, {
    Duration warning = Secret.expiryWarning,
  }) {
    final expiresAt = this.expiresAt;
    if (expiresAt == null) return ExpiryStatus.none;
    if (!now.isBefore(expiresAt)) return ExpiryStatus.expired;
    if (!now.add(warning).isBefore(expiresAt)) return ExpiryStatus.expiringSoon;
    return ExpiryStatus.valid;
  }

  /// A copy for "duplicate in the same file": a new id and both timestamps
  /// set to now. Moves and copies to other files keep the original instead.
  Secret duplicate({Clock clock = const Clock()}) {
    final now = clock.now();
    return withInfo(info.copyWith(id: newId(), createdAt: now, updatedAt: now));
  }

  /// [edited] stamped as an edit of [original]: same id and `createdAt` as
  /// the original, and `updatedAt` set to now if the content changed.
  /// Returns [original] unchanged if nothing changed.
  ///
  /// Throws [ArgumentError] if [edited] is a different secret.
  static T applyEdit<T extends Secret>(
    T original,
    T edited, {
    Clock clock = const Clock(),
  }) {
    if (edited.id != original.id) {
      throw ArgumentError.value(edited, 'edited', 'Different secret id');
    }
    if (edited.sameContentAs(original)) return original;
    return edited.withInfo(
      edited.info.copyWith(
        createdAt: original.createdAt,
        updatedAt: clock.now(),
      ),
    ) as T;
  }

  /// The JSON stored in the vault payload: `type`, the common fields, then
  /// the type-specific fields.
  Map<String, Object?> toJson() => {
    'type': type.name,
    ...info.toJson(),
    ..._contentJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Secret &&
      other.runtimeType == runtimeType &&
      other.info == info &&
      _sameTypeContent(other);

  @override
  int get hashCode => Object.hash(type, info, _contentHash);

  /// Only the type and id, never titles or values.
  @override
  String toString() => '${type.name} secret ($id)';
}

/// A single password, e.g. a Wi-Fi key or a disk encryption passphrase.
final class PasswordSecret extends Secret {
  const PasswordSecret({required SecretInfo info, required this.password})
    : super(info);

  final String password;

  @override
  SecretType get type => SecretType.password;

  @override
  PasswordSecret withInfo(SecretInfo info) => copyWith(info: info);

  PasswordSecret copyWith({SecretInfo? info, String? password}) =>
      PasswordSecret(
        info: info ?? this.info,
        password: password ?? this.password,
      );

  @override
  Map<String, Object?> _contentJson() => {'password': password};

  @override
  bool _sameTypeContent(PasswordSecret other) => other.password == password;

  @override
  int get _contentHash => password.hashCode;
}

/// An account: username, password, sign-in URL and optional 2FA seed.
/// Empty strings mean "not set".
final class LoginSecret extends Secret {
  const LoginSecret({
    required SecretInfo info,
    this.username = '',
    this.password = '',
    this.url = '',
    this.totp = '',
  }) : super(info);

  final String username;
  final String password;

  /// Sign-in page, opened in the browser.
  final String url;

  /// TOTP seed for two-factor codes: an `otpauth://totp/…` URI or a base32
  /// secret, stored as entered.
  final String totp;

  @override
  SecretType get type => SecretType.login;

  @override
  LoginSecret withInfo(SecretInfo info) => copyWith(info: info);

  LoginSecret copyWith({
    SecretInfo? info,
    String? username,
    String? password,
    String? url,
    String? totp,
  }) => LoginSecret(
    info: info ?? this.info,
    username: username ?? this.username,
    password: password ?? this.password,
    url: url ?? this.url,
    totp: totp ?? this.totp,
  );

  @override
  Map<String, Object?> _contentJson() => {
    'username': username,
    'password': password,
    'url': url,
    'totp': totp,
  };

  @override
  bool _sameTypeContent(LoginSecret other) =>
      other.username == username &&
      other.password == password &&
      other.url == url &&
      other.totp == totp;

  @override
  int get _contentHash => Object.hash(username, password, url, totp);
}

/// A PEM document: certificates, public or private keys, or a chain of them.
final class PemSecret extends Secret {
  const PemSecret({required SecretInfo info, required this.pem}) : super(info);

  // Matches "PRIVATE KEY", "RSA PRIVATE KEY", "ENCRYPTED PRIVATE KEY",
  // "OPENSSH PRIVATE KEY", ...
  static final _privateKeyHeader = RegExp(
    r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----',
  );

  /// The PEM text, as pasted or loaded from a file.
  final String pem;

  /// Whether [pem] contains a private key, which the UI masks.
  bool get containsPrivateKey => _privateKeyHeader.hasMatch(pem);

  @override
  SecretType get type => SecretType.pem;

  @override
  PemSecret withInfo(SecretInfo info) => copyWith(info: info);

  PemSecret copyWith({SecretInfo? info, String? pem}) =>
      PemSecret(info: info ?? this.info, pem: pem ?? this.pem);

  @override
  Map<String, Object?> _contentJson() => {'pem': pem};

  @override
  bool _sameTypeContent(PemSecret other) => other.pem == pem;

  @override
  int get _contentHash => pem.hashCode;
}

/// One single-use code of a [RecoveryCodesSecret].
@immutable
final class RecoveryCode {
  const RecoveryCode(this.code, {this.used = false});

  factory RecoveryCode.fromJson(Object? json) {
    final map = readObject(json, 'recovery code');
    return RecoveryCode(
      readField<String>(map, 'code', 'recovery code'),
      used: readField<bool>(map, 'used', 'recovery code'),
    );
  }

  final String code;
  final bool used;

  Map<String, Object?> toJson() => {'code': code, 'used': used};

  @override
  bool operator ==(Object other) =>
      other is RecoveryCode && other.code == code && other.used == used;

  @override
  int get hashCode => Object.hash(code, used);

  @override
  String toString() => 'RecoveryCode(<redacted>, used: $used)';
}

/// Backup codes of an account, each usable once.
final class RecoveryCodesSecret extends Secret {
  RecoveryCodesSecret({
    required SecretInfo info,
    Iterable<RecoveryCode> codes = const [],
  }) : codes = List.unmodifiable(codes),
       super(info);

  /// Codes in the order the service listed them.
  final List<RecoveryCode> codes;

  /// Number of unused codes.
  int get remaining => codes.where((code) => !code.used).length;

  /// Copy with the code at [index] marked [used] (or unused).
  RecoveryCodesSecret withCodeUsed(int index, {bool used = true}) => copyWith(
    codes: [
      for (final (i, code) in codes.indexed)
        i == index ? RecoveryCode(code.code, used: used) : code,
    ],
  );

  @override
  SecretType get type => SecretType.recoveryCodes;

  @override
  RecoveryCodesSecret withInfo(SecretInfo info) => copyWith(info: info);

  RecoveryCodesSecret copyWith({
    SecretInfo? info,
    Iterable<RecoveryCode>? codes,
  }) =>
      RecoveryCodesSecret(info: info ?? this.info, codes: codes ?? this.codes);

  @override
  Map<String, Object?> _contentJson() => {
    'codes': [for (final code in codes) code.toJson()],
  };

  @override
  bool _sameTypeContent(RecoveryCodesSecret other) =>
      const ListEquality<RecoveryCode>().equals(other.codes, codes);

  @override
  int get _contentHash => Object.hashAll(codes);
}

/// Free-form secret text, e.g. a safe combination or a seed phrase.
final class NoteSecret extends Secret {
  const NoteSecret({required SecretInfo info, required this.text})
    : super(info);

  /// The secret text. Unlike `notes`, the UI masks it.
  final String text;

  @override
  SecretType get type => SecretType.note;

  @override
  NoteSecret withInfo(SecretInfo info) => copyWith(info: info);

  NoteSecret copyWith({SecretInfo? info, String? text}) =>
      NoteSecret(info: info ?? this.info, text: text ?? this.text);

  @override
  Map<String, Object?> _contentJson() => {'text': text};

  @override
  bool _sameTypeContent(NoteSecret other) => other.text == text;

  @override
  int get _contentHash => text.hashCode;
}
