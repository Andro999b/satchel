import 'dart:math';

/// Character classes for [generatePassword]. Visually ambiguous characters
/// (`I l 1 O 0`) are left out so passwords are easy to read and type.
abstract final class PasswordAlphabet {
  static const lowercase = 'abcdefghijkmnopqrstuvwxyz';
  static const uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const digits = '23456789';
  static const symbols = r'!#$%&()*+,-./:;<=>?@[]^_{|}~';
}

/// Generates a random password of [length] characters with at least one
/// character from each enabled class, using a cryptographically secure
/// [random] by default.
///
/// Throws [ArgumentError] if no class is enabled or [length] is shorter than
/// the number of enabled classes.
String generatePassword({
  int length = 20,
  bool lowercase = true,
  bool uppercase = true,
  bool digits = true,
  bool symbols = true,
  Random? random,
}) {
  final classes = [
    if (lowercase) PasswordAlphabet.lowercase,
    if (uppercase) PasswordAlphabet.uppercase,
    if (digits) PasswordAlphabet.digits,
    if (symbols) PasswordAlphabet.symbols,
  ];
  if (classes.isEmpty) {
    throw ArgumentError('Enable at least one character class');
  }
  if (length < classes.length) {
    throw ArgumentError.value(length, 'length', 'Too short for the classes');
  }
  final rng = random ?? Random.secure();
  String pick(String alphabet) => alphabet[rng.nextInt(alphabet.length)];
  final all = classes.join();
  final chars = [
    for (final alphabet in classes) pick(alphabet),
    for (var i = classes.length; i < length; i++) pick(all),
  ];
  // Fisher–Yates, so the guaranteed characters are not always first.
  for (var i = chars.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final swap = chars[i];
    chars[i] = chars[j];
    chars[j] = swap;
  }
  return chars.join();
}
