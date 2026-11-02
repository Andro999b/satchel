import 'dart:math';

/// [Random] returning a fixed byte sequence, for deterministic salts and
/// nonces in known-answer tests.
final class SequenceRandom implements Random {
  SequenceRandom(this.bytes);

  final List<int> bytes;
  var _index = 0;

  @override
  int nextInt(int max) {
    if (max != 256) throw UnsupportedError('Only bytes are supported');
    return bytes[_index++ % bytes.length];
  }

  @override
  bool nextBool() => throw UnsupportedError('nextBool');

  @override
  double nextDouble() => throw UnsupportedError('nextDouble');
}
