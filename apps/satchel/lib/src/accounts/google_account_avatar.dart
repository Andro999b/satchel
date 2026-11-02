import 'package:flutter/material.dart';
import 'package:satchel_storage/satchel_storage.dart';

/// The initial of a Google account's name or email in a circle. No photo:
/// Satchel loads nothing beyond its storages.
class GoogleAccountAvatar extends StatelessWidget {
  const GoogleAccountAvatar({super.key, required this.account});

  final GoogleAccount account;

  @override
  Widget build(BuildContext context) {
    final name = account.displayName.isEmpty
        ? account.email
        : account.displayName;
    return CircleAvatar(
      child: Text(name.characters.firstOrNull?.toUpperCase() ?? '?'),
    );
  }
}
