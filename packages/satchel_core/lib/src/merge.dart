import 'package:clock/clock.dart';

import 'secret.dart';
import 'vault_payload.dart';

/// A secret with the same id in both files but different content.
final class SecretConflict {
  const SecretConflict({required this.existing, required this.incoming});

  /// The version in the destination.
  final Secret existing;

  /// The version being merged in.
  final Secret incoming;

  String get id => existing.id;

  /// Whether [incoming] was changed more recently, to suggest it. Never
  /// applied without the user's choice.
  bool get incomingIsNewer => incoming.updatedAt.isAfter(existing.updatedAt);
}

/// How the user resolved a [SecretConflict].
enum ConflictResolution { keepExisting, useIncoming }

/// What merging one vault into another would do, matched by secret id.
final class MergePlan {
  MergePlan({
    required List<Secret> added,
    required List<Secret> identical,
    required List<SecretConflict> conflicts,
  }) : added = List.unmodifiable(added),
       identical = List.unmodifiable(identical),
       conflicts = List.unmodifiable(conflicts);

  /// Secrets only in the source: they are added.
  final List<Secret> added;

  /// Secrets already in the destination with the same content: skipped.
  final List<Secret> identical;

  /// Secrets in both with different content: the user decides.
  final List<SecretConflict> conflicts;

  /// Whether merging can't change the destination.
  bool get isEmpty => added.isEmpty && conflicts.isEmpty;
}

/// Plans merging the secrets of [source] into [destination]. Pure: no I/O.
MergePlan planMerge({
  required VaultPayload source,
  required VaultPayload destination,
}) {
  final added = <Secret>[];
  final identical = <Secret>[];
  final conflicts = <SecretConflict>[];
  for (final incoming in source.secrets) {
    final existing = destination.secretById(incoming.id);
    if (existing == null) {
      added.add(incoming);
    } else if (existing.sameContentAs(incoming)) {
      identical.add(incoming);
    } else {
      conflicts.add(SecretConflict(existing: existing, incoming: incoming));
    }
  }
  return MergePlan(added: added, identical: identical, conflicts: conflicts);
}

/// Applies [plan] to [destination]: adds the new secrets and replaces
/// conflicting ones where [resolutions] (by secret id) say so. Secrets keep
/// their own timestamps; the file's `updatedAt` is bumped if anything
/// changed. Returns [destination] itself if nothing did.
///
/// Throws [ArgumentError] if a conflict has no resolution: conflicts are
/// never resolved silently.
VaultPayload applyMerge(
  VaultPayload destination,
  MergePlan plan,
  Map<String, ConflictResolution> resolutions, {
  Clock clock = const Clock(),
}) {
  final unresolved = plan.conflicts.where(
    (conflict) => !resolutions.containsKey(conflict.id),
  );
  if (unresolved.isNotEmpty) {
    throw ArgumentError.value(resolutions, 'resolutions', 'Missing a conflict');
  }
  var merged = destination;
  for (final secret in plan.added) {
    merged = merged.withSecret(secret, clock: clock);
  }
  for (final conflict in plan.conflicts) {
    if (resolutions[conflict.id] == ConflictResolution.useIncoming) {
      merged = merged.withSecret(conflict.incoming, clock: clock);
    }
  }
  return merged;
}
