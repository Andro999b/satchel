import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates a new random identifier for files and secrets (UUID v4).
String newId() => _uuid.v4();
