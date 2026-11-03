# Satchel

Satchel is an offline-capable password and secrets keeper built with Flutter. Vaults are encrypted on your device and stored in locations you choose; Satchel has no backend.

The app supports web, Android, Linux, and Windows. It can store vaults locally or in Google Drive, and organize passwords, logins, notes, recovery codes, and other secrets in encrypted vault files.

## Getting started

Satchel uses [FVM](https://fvm.app/) to manage its Flutter SDK. From the repository root:

```sh
fvm install
fvm flutter pub get
cd apps/satchel
fvm flutter run -d chrome
```

To run on another available target, replace `chrome` with `linux` or an Android device ID.

Google Drive sign-in is optional. To enable it for local development, copy `apps/satchel/google_oauth.example.json` to `apps/satchel/google_oauth.json`, fill in your OAuth client values, then run the app with:

```sh
fvm flutter run --dart-define-from-file=google_oauth.json -d chrome
```

The local OAuth file is not committed. Without OAuth configuration, the app still runs but cannot add Google accounts.

## Project structure

- `apps/satchel`: Flutter application.
- `packages/satchel_core`: Pure Dart domain models, encryption, vault format, and merge logic.
- `packages/satchel_storage`: Storage interfaces and platform-specific providers.

## Checks

Run these commands from the repository root:

```sh
fvm dart format .
fvm dart analyze --fatal-infos
```

Run tests from each package or app directory with `fvm dart test` for `satchel_core` and `fvm flutter test` for the Flutter packages and app.
