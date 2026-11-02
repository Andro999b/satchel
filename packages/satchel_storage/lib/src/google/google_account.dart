import 'package:flutter/foundation.dart';

/// A Google account linked to Satchel. Identity only: never holds tokens.
@immutable
final class GoogleAccount {
  const GoogleAccount({
    required this.id,
    required this.email,
    this.displayName = '',
  });

  /// Parses [toJson] output. Throws [FormatException] on malformed input.
  factory GoogleAccount.fromJson(Map<String, Object?> json) {
    if (json case {'id': final String id, 'email': final String email}) {
      final displayName = json['displayName'] ?? '';
      if (displayName is! String) {
        throw const FormatException('Account name must be a string');
      }
      return GoogleAccount(id: id, email: email, displayName: displayName);
    }
    throw const FormatException('Malformed Google account');
  }

  /// Stable Google account id (the OpenID `sub`). Emails can change.
  final String id;

  final String email;

  /// The user's name, or empty if Google didn't provide one.
  final String displayName;

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    if (displayName.isNotEmpty) 'displayName': displayName,
  };

  @override
  bool operator ==(Object other) =>
      other is GoogleAccount &&
      other.id == id &&
      other.email == email &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(id, email, displayName);

  @override
  String toString() => 'GoogleAccount($id, $email)';
}
