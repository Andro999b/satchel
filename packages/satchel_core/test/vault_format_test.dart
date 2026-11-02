import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

void main() {
  test('recognizes vault file names', () {
    expect(isVaultFileName('personal.satchel'), isTrue);
    expect(isVaultFileName('.satchel'), isFalse);
    expect(isVaultFileName('notes.txt'), isFalse);
    expect(isVaultFileName('satchel'), isFalse);
  });

  test('derives the vault name from the path', () {
    expect(vaultNameFromPath('personal.satchel'), 'personal');
    expect(vaultNameFromPath('a.b.satchel'), 'a.b');
    expect(vaultNameFromPath('notes.txt'), 'notes.txt');
  });

  test('accepts ordinary names', () {
    for (final name in [
      'Personal',
      'work 2026',
      'a.b',
      'Ключі',
      '🔑 keys',
      'x' * 100,
    ]) {
      expect(checkVaultName(name), isNull, reason: name);
      expect(vaultPathForName(name), '$name.satchel');
    }
  });

  test('rejects names that are not portable file names', () {
    const cases = {
      '': VaultNameError.empty,
      ' Personal': VaultNameError.surroundingWhitespace,
      'Personal ': VaultNameError.surroundingWhitespace,
      '.hidden': VaultNameError.leadingDot,
      'dots.': VaultNameError.trailingDot,
      'a/b': VaultNameError.invalidCharacter,
      r'a\b': VaultNameError.invalidCharacter,
      'a:b': VaultNameError.invalidCharacter,
      'what?': VaultNameError.invalidCharacter,
      'tab\there': VaultNameError.invalidCharacter,
      'CON': VaultNameError.reservedName,
      'nul': VaultNameError.reservedName,
      'Lpt1': VaultNameError.reservedName,
    };
    cases.forEach((name, error) {
      expect(checkVaultName(name), error, reason: name);
      expect(() => vaultPathForName(name), throwsArgumentError, reason: name);
    });
    expect(checkVaultName('x' * 101), VaultNameError.tooLong);
    expect(checkVaultName('console'), isNull);
  });
}
