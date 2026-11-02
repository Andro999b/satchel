import 'package:satchel_core/satchel_core.dart';

final created = DateTime.utc(2026, 3, 1, 9, 30);
final updated = DateTime.utc(2026, 10, 15, 18, 45, 12, 345);

SecretInfo info(
  String id, {
  String title = 'Title',
  List<String> tags = const [],
  DateTime? expiresAt,
  String notes = '',
  List<CustomField> customFields = const [],
}) => SecretInfo(
  id: id,
  title: title,
  createdAt: created,
  updatedAt: updated,
  tags: tags,
  expiresAt: expiresAt,
  notes: notes,
  customFields: customFields,
);

/// One secret of every type, using every optional field at least once.
/// Also the content of the `secrets.satchel` golden file: never change it.
final List<Secret> allSecretTypes = [
  PasswordSecret(
    info: info(
      '11111111-1111-4111-8111-111111111111',
      title: 'Home Wi-Fi',
      tags: ['home', 'network'],
    ),
    password: 'c0rrect-h0rse',
  ),
  LoginSecret(
    info: info(
      '22222222-2222-4222-8222-222222222222',
      title: 'Example Bank',
      tags: ['finance'],
      notes: 'Shared with Ann.\nRotate yearly.',
      expiresAt: DateTime.utc(2027, 1, 1),
      customFields: [
        const CustomField(
          label: 'Customer number',
          value: '12345',
          concealed: false,
        ),
        const CustomField(label: 'Security answer', value: 'Rex'),
      ],
    ),
    username: 'ann@example.com',
    password: 'p@ss wörd 🔑',
    url: 'https://bank.example.com/login',
    totp: 'otpauth://totp/Example:ann?secret=JBSWY3DPEHPK3PXP&issuer=Example',
  ),
  PemSecret(
    info: info(
      '33333333-3333-4333-8333-333333333333',
      title: 'Server key',
      expiresAt: DateTime.utc(2026, 12, 31, 23, 59, 59),
    ),
    pem:
        '-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIA==\n'
        '-----END PRIVATE KEY-----\n',
  ),
  RecoveryCodesSecret(
    info: info(
      '44444444-4444-4444-8444-444444444444',
      title: 'Mail backup codes',
    ),
    codes: const [
      RecoveryCode('1111-2222', used: true),
      RecoveryCode('3333-4444'),
      RecoveryCode('5555-6666'),
    ],
  ),
  NoteSecret(
    info: info('55555555-5555-4555-8555-555555555555', title: 'Safe'),
    text: 'Combination: 12-34-56',
  ),
];
