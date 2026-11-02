import 'dart:math';

import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

void main() {
  test('defaults to 20 characters from every class', () {
    for (var i = 0; i < 50; i++) {
      final password = generatePassword();

      expect(password, hasLength(20));
      for (final alphabet in [
        PasswordAlphabet.lowercase,
        PasswordAlphabet.uppercase,
        PasswordAlphabet.digits,
        PasswordAlphabet.symbols,
      ]) {
        expect(password.split('').any(alphabet.contains), isTrue);
      }
    }
  });

  test('uses only the enabled classes', () {
    final password = generatePassword(
      length: 64,
      uppercase: false,
      symbols: false,
    );

    expect(
      password
          .split('')
          .every(
            (c) =>
                PasswordAlphabet.lowercase.contains(c) ||
                PasswordAlphabet.digits.contains(c),
          ),
      isTrue,
    );
    expect(password.split('').any(PasswordAlphabet.digits.contains), isTrue);
  });

  test('never uses ambiguous characters', () {
    final password = generatePassword(length: 500);

    expect(password, isNot(matches(RegExp('[Il1O0]'))));
  });

  test('is random', () {
    final passwords = {for (var i = 0; i < 100; i++) generatePassword()};

    expect(passwords, hasLength(100));
  });

  test('is deterministic for a given random source', () {
    expect(
      generatePassword(random: Random(1)),
      generatePassword(random: Random(1)),
    );
  });

  test('rejects impossible requests', () {
    expect(
      () => generatePassword(
        lowercase: false,
        uppercase: false,
        digits: false,
        symbols: false,
      ),
      throwsArgumentError,
    );
    expect(() => generatePassword(length: 3), throwsArgumentError);
    expect(generatePassword(length: 4), hasLength(4));
  });
}
