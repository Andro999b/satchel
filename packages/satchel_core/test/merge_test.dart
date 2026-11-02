import 'package:clock/clock.dart';
import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

import 'secret_fixtures.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 12);
  final clock = Clock.fixed(now);
  final login = allSecretTypes.whereType<LoginSecret>().first;
  final others = allSecretTypes.where((s) => s.id != login.id).toList();
  final edited = Secret.applyEdit(
    login,
    login.copyWith(username: 'someone-else'),
    clock: Clock.fixed(DateTime.utc(2030)),
  );

  VaultPayload vault(List<Secret> secrets) => VaultPayload(
    fileId: 'f',
    name: 'Personal',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026, 2),
    secrets: secrets,
  );

  group('planMerge', () {
    test('classifies new, identical and conflicting secrets', () {
      final plan = planMerge(
        source: vault([others[0], edited, others[1]]),
        destination: vault([login, others[1]]),
      );

      expect(plan.added, [others[0]]);
      expect(plan.identical, [others[1]]);
      expect(plan.conflicts.single.existing, login);
      expect(plan.conflicts.single.incoming, edited);
      expect(plan.conflicts.single.id, login.id);
      expect(plan.isEmpty, isFalse);
    });

    test('only timestamps differing is not a conflict', () {
      final touched = login.withInfo(
        login.info.copyWith(updatedAt: DateTime.utc(2026, 9)),
      );

      final plan = planMerge(
        source: vault([touched]),
        destination: vault([login]),
      );

      expect(plan.identical, [touched]);
      expect(plan.isEmpty, isTrue);
    });

    test('suggests the newer version', () {
      final conflict = SecretConflict(existing: login, incoming: edited);
      final reversed = SecretConflict(existing: edited, incoming: login);

      expect(conflict.incomingIsNewer, isTrue);
      expect(reversed.incomingIsNewer, isFalse);
    });
  });

  group('applyMerge', () {
    final destination = vault([login, others[1]]);
    final plan = planMerge(
      source: vault([others[0], edited]),
      destination: destination,
    );

    test('adds new secrets and keeps the existing version', () {
      final merged = applyMerge(destination, plan, {
        login.id: ConflictResolution.keepExisting,
      }, clock: clock);

      expect(merged.secrets, [login, others[1], others[0]]);
      expect(merged.updatedAt, now);
      expect(merged.fileId, 'f');
    });

    test('replaces in place with the incoming version', () {
      final merged = applyMerge(destination, plan, {
        login.id: ConflictResolution.useIncoming,
      }, clock: clock);

      expect(merged.secrets, [edited, others[1], others[0]]);
      // Merged secrets keep their own timestamps.
      expect(merged.secretById(login.id)!.updatedAt, edited.updatedAt);
      expect(merged.secretById(login.id)!.createdAt, login.createdAt);
    });

    test('changes nothing when there is nothing to take', () {
      final noop = planMerge(source: vault([edited]), destination: destination);

      final merged = applyMerge(destination, noop, {
        login.id: ConflictResolution.keepExisting,
      }, clock: clock);

      expect(identical(merged, destination), isTrue);
    });

    test('refuses unresolved conflicts', () {
      expect(
        () => applyMerge(destination, plan, const {}, clock: clock),
        throwsArgumentError,
      );
    });
  });
}
