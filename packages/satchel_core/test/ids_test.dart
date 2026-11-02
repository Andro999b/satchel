import 'package:satchel_core/satchel_core.dart';
import 'package:test/test.dart';

void main() {
  group('newId', () {
    test('returns a UUID v4', () {
      expect(
        newId(),
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('returns unique values', () {
      final ids = {for (var i = 0; i < 1000; i++) newId()};
      expect(ids, hasLength(1000));
    });
  });
}
