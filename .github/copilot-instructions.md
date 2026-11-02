# Copilot instructions for Satchel

Satchel is a serverless password/secrets keeper built with Flutter from a single codebase. Target platforms are **web, Android, Linux, and Windows** (no iOS/macOS), and it works offline. There is **no backend**: encrypted vault files live in user-chosen storage providers (local disk, Google Drive, …) and are only ever decrypted on the client.

> Parts of this file describe the intended design ahead of the code. When the implementation diverges, update this file in the same change.

## Build, test, lint

Dart pub workspace monorepo. The root `pubspec.yaml` lists members under `workspace:`, and each member has `resolution: workspace`. There is **one shared `pubspec.lock` and `.dart_tool/` at the root**, so all members must agree on every transitive version.

The Flutter SDK is managed with **fvm**. The pinned version lives in `.fvmrc` (currently Flutter 3.47.9 / Dart 3.13.7). **Always invoke tooling as `fvm flutter …` / `fvm dart …`**, never a bare `flutter`/`dart` from `PATH`. Run `fvm install` after cloning or after `.fvmrc` changes. Change the version with `fvm use <version>` (this updates `.fvmrc` and `.vscode/settings.json`). Never hand-edit those files. `.fvm/` is a local SDK link and is gitignored. Keep every member's `environment: sdk:` constraint (`^3.13.0`) in line with the pinned Dart version.

```sh
fvm install                              # install the SDK pinned in .fvmrc
fvm flutter pub get                      # from repo root, resolves all workspace members
(cd apps/satchel && fvm dart run build_runner build --delete-conflicting-outputs)   # required after pub get: *.g.dart is gitignored
(cd apps/satchel && fvm flutter gen-l10n)   # regenerate localizations after editing ARB files (pub get/run/test/build also do it)
fvm dart format .                        # format everything
fvm dart analyze --fatal-infos           # from root, all packages; CI fails on any lint

# satchel_core (pure Dart -> `dart test`)
cd packages/satchel_core && fvm dart test
fvm dart test test/ids_test.dart                                  # single file
fvm dart test test/ids_test.dart --name "returns a UUID v4"       # single test

# satchel_storage and the app (Flutter -> `flutter test`)
cd packages/satchel_storage && fvm flutter test
fvm flutter test --platform chrome test/*_test.dart   # browser run (IndexedDB); add --wasm for dart2wasm. Excludes VM-only test/directory/
cd apps/satchel && fvm flutter test
fvm flutter test test/storage/storages_pane_test.dart --plain-name "opens the files of a storage"   # single test
fvm flutter test integration_test                                # integration tests (needs a device)

# Run / build the app
cd apps/satchel
fvm flutter run -d chrome | -d linux | -d <android-device-id>
fvm flutter build web --wasm | fvm flutter build linux | fvm flutter build apk
fvm flutter build windows                # only on a Windows host
```

CI (`.github/workflows/ci.yml`) runs pub get, codegen, the format check, analyze with `--fatal-infos`, all three test suites (plus `satchel_storage` again in Chrome with dart2js and dart2wasm), and `flutter build web --wasm`. It reads the Flutter version from `.fvmrc` via `subosito/flutter-action`'s `flutter-version-file`. Never hard-code a version there.

Dependencies:
- Add them with `fvm dart pub add` / `fvm flutter pub add` inside the member, not by editing pubspecs by hand.
- Workspace members depend on each other with `path:` dependencies.
- `flutter_test` pins `test_api`, so `satchel_core`'s `test` dev dependency must stay at a version compatible with that pin. If resolution fails on `test`/`test_api`/`analyzer`, that shared pin is the cause.

Lint config is layered. The root `analysis_options.yaml` holds the shared strict settings (`strict-casts/inference/raw-types` and extra rules). Each member's `analysis_options.yaml` uses `include: [<lint set>, ../../analysis_options.yaml]`, with `package:lints/recommended.yaml` for `satchel_core` and `package:flutter_lints/flutter.yaml` for the Flutter packages. Put new shared rules in the root file.

## Architecture

```
packages/satchel_core       Pure Dart. Domain model, vault file format, crypto (KDF + AEAD), merge planning, import/export. No Flutter, no I/O.
packages/satchel_storage    StorageProvider interface + implementations (local file, Google Drive). Flutter plugins allowed.
apps/satchel                Flutter app: UI, state, PIN unlock, platform integration. Depends on both packages.
```

### App state (Riverpod)
- State management is **Riverpod** (`flutter_riverpod` + `riverpod_annotation`/`riverpod_generator`). Use code-generated `@riverpod` providers, not hand-written `Provider(...)` declarations. Regenerate with `fvm dart run build_runner build --delete-conflicting-outputs` (or `watch`) from `apps/satchel`.
- Providers mirror the data hierarchy: `storageProvidersProvider` → `vaultFilesProvider(storageId)` → `unlockedVaultsProvider[VaultRef(storageId, path)]` → `payload.secrets`.
- Platform-dependent choices go through `storagePlatformProvider` (wraps `StoragePlatform.current`) so tests can simulate any platform with `storagePlatformProvider.overrideWithValue(...)`. `availableStorageKindsProvider` lists the storage kinds usable on it, and `addableStorageKindsProvider` lists the ones the user can add.
- Configured storages (all in `lib/src/storage/`): `storageConfigsProvider` (keep-alive `AsyncNotifier`, non-secret settings only) returns the built-in storages for the platform (the "This browser" IndexedDB storage on web) followed by the user-added ones. Its `add`/`remove`/`pickDirectory`/`hasLocation` methods back the add/remove UI in `storage_actions.dart`. User-added `StorageConfig`s persist as JSON via `StorageConfigStore` (`SharedPreferencesStorageConfigStore`, key `satchel.storages.v1`). Several storages of a kind are allowed, but not two for the same location. Removing one never deletes files, and it releases the Android folder permission once no other storage uses that folder. `storageProvidersProvider` builds a `StorageProvider` from each config with `kind.create(config)`.
- Decrypted vault state lives **only** in the unlocked-vault session, `unlockedVaultsProvider` (`lib/src/vault/unlocked_vaults.dart`). It's a keep-alive `Map<VaultRef, UnlockedVault>` of payload, `VaultKey` and storage revision, so unlocked files stay unlocked while their panes are closed and the files pane can show the lock state.
  - `unlock(ref, password)` reads and decrypts a file. `adopt(...)` adds a vault that was just created and takes ownership of its key.
  - `save(ref, change)` (and `putSecret`) is the only way to write an unlocked vault. It encrypts with the session key and a fresh nonce (no KDF), writes with `expectedRevision:` the session's revision (`StorageConflictException` if the file changed elsewhere; nothing is overwritten, and the merge flow will handle it later), then reads back and decrypts to verify. Only then does the session show the new content. If verification fails, the session keeps the old content but takes the new revision, so a retry overwrites the bad copy. Saves of one vault are serialized.
  - `lock(ref)` and `lockAll()` zero the key (`VaultKey.destroy`) and drop the payload. Removing a storage locks its files, and disposing the app zeroes every key.
  - Lock through these methods only; never copy keys or payloads into other long-lived providers or widget state. Derive per-file views with `ref.watch(unlockedVaultsProvider.select((v) => v[vaultRef]))`.
  - Auto-lock (inactivity, app backgrounded) will call `lockAll()`.
- Widgets read state through `ref.watch` and trigger actions through notifier methods. They don't call `satchel_core`/`satchel_storage` directly.
- In tests, override providers with `ProviderContainer(overrides: [...])` / `ProviderScope(overrides: [...])`, e.g. `storageConfigStoreProvider.overrideWithValue(...)`, `directoryPickerProvider.overrideWithValue(...)`, `vaultCryptoProvider.overrideWithValue(const VaultCrypto(memoryKiB: 64))` (cheap KDF), and `appClockProvider.overrideWithValue(Clock.fixed(...))` (fakes, including an in-memory `FakeStorageProvider`, are in `test/fakes.dart`). In widget tests, let real crypto finish by alternating `tester.runAsync` and `tester.pump`. Use fakes rather than real I/O or platform plugins.
- App code is organized by feature under `lib/src/<feature>/`. Each feature's providers sit next to its widgets, and `lib/main.dart` only wraps `SatchelApp` in a `ProviderScope`. Current features:
  - `navigation/`: `AppShell` (the adaptive layout), `currentLocationProvider`, and the pure layout math in `adaptive_layout.dart`.
  - `storage/`: `StoragesPane` (list, add, remove).
  - `files/`: `FilesPane`, which lists the vault files of one storage (`storageByIdProvider(id)` → `vaultFilesProvider(id)`, as `VaultFile`s named by their path until unlocked). Its "New file" FAB opens `NewVaultFileDialog` (name, password ≥ 8 characters, and confirmation), which calls `VaultFiles.create`. That checks for a name clash (ignoring case), seals an empty `VaultPayload` via `vaultCryptoProvider`, writes it with `expectedRevision: null`, then reads it back and decrypts it to verify, deleting it if verification fails. On success it `adopt`s the vault into the session, so the new file opens unlocked.
  - `vault/`: `unlockedVaultsProvider` (the session, see above), `vaultCryptoProvider` (`VaultCrypto`: KDF settings plus sealing), and `appClockProvider` (the injected `Clock`).
  - `files/` list tiles show each file's lock state: a `lock_outline` or `lock_open` icon, with "Locked"/"Unlocked" as tooltip and semantic label. Each tile's trailing "More actions" (`more_vert`) `MenuAnchor` holds Rename, Change password, Export (unlocked only) and Delete. They act on the **unlocked session's revision** if the file is unlocked, otherwise the **listed** one. The name and new-password inputs are shared through `vault_file_fields.dart` (`vaultNameErrorText`, `NewPasswordFields` with generate and reveal).
  - Rename (`rename_vault_file.dart`) is enabled only while the file is unlocked, because the name is also stored in the encrypted payload. `UnlockedVaults.rename` checks for a name clash (ignoring case, except the file itself), writes the payload `withName` under the session key to the new path (`expectedRevision: null`), reads it back to verify, then deletes the old file at the session's revision. If any step fails it removes the new copy, so the original is never lost. It then moves the session entry to the new `VaultRef`, and `CurrentLocation.renameFile` follows the open file.
  - Change password (`change_vault_password.dart`) works locked or unlocked and keeps that state. It always asks for the current password. `UnlockedVaults.changePassword` reads the file, decrypts it with the current password (if unlocked, the session revision must match, else `StorageConflictException`), seals it under the new password with a fresh salt, writes at the read revision, and verifies. On a failed verify it writes the original bytes back. An unlocked session swaps to the new key and destroys the old one.
  - Delete: `deleteVaultFile` (`files/delete_vault_file.dart`) shows `DeleteVaultFileDialog`, a destructive confirmation naming the file and storage, with Cancel focused. Then `VaultFiles.delete` calls `storage.delete` with the expected revision above (so content changed after unlocking is never deleted unseen). A mismatch throws `StorageConflictException` and refreshes the list instead of deleting; an already missing file counts as deleted. A deleted file is then locked, closed (`CurrentLocation.closeFile`), and the outcome reported in a snack bar. Never delete without the user's confirmation, and never retry a delete with a fresh revision automatically.
  - `secrets/`: `SecretsPane` is the pane of one vault file. While the file is locked it shows the unlock form: the password field (autofocus; Enter submits; Unlock is disabled while empty), progress while the KDF runs, and localized errors for a wrong password, a missing key file, a newer format, an invalid file, or a read failure. After a wrong password the field is refocused with its text selected. Once the file is unlocked it lists the secrets (icon per type from `secret_display.dart`; tap opens one; expired/expiring-soon secrets are highlighted, see below; each row's "More actions" (`more_vert`) `MenuAnchor` offers Select, Edit and Delete, the same `showSecretEditor`/`deleteSecret` as the secret pane) and its app bar has a Lock button.
  - `SecretPane` (`secret_pane.dart`) shows one secret with Edit and Delete in its app bar, switching exhaustively on the type.
    - Values are masked as a fixed `maskedValue` (so length isn't revealed), with per-field reveal, and copy via `secretClipboardProvider`. `SecretClipboard` clears the clipboard after 30 s unless something else was copied; `copyValue` shows a snack bar saying so.
    - Login: username, masked password, URL with "open in browser" (`url_launcher`, http(s) only), and masked TOTP. Empty login fields are hidden.
    - PEM: monospace in a box, collapsed to 4 lines with Show all/less, masked behind "Contains a private key" when `containsPrivateKey`.
    - Recovery codes: an "N codes left" header (warning at ≤ `lowRecoveryCodes` = 2) and a masked checklist. Ticking a code saves it via `Secret.applyEdit` + `putSecret`.
    - Note: masked multiline text. For every type it also shows notes, custom fields (masked when `concealed`), tags as chips, a header badge (the `ExpiryHighlight` icon and relative text on its container color), and the expiry plus created/updated times (expiry text in the highlight's `foreground` color) (`intl` `DateFormat`, local time).
    - Reveal/expand state is keyed by secret id, so it resets when another secret is shown. A secret that no longer exists shows a message, and `CurrentLocation` also closes a secret that was deleted.
  - Editing: `showSecretEditor(context, vault:, initial: secret)` opens the same editor prefilled, titled "Edit …", with "More options" expanded if any optional field is set. It builds from `initial.info.copyWith(...)` and then `Secret.applyEdit`, so the id and `createdAt` are kept, `updatedAt` is bumped only on real changes, and an unchanged save writes nothing.
    - The validity field is prefilled with the remaining days (rounded up), but the **original `expiresAt` is kept unless the user edits the validity**.
    - Recovery codes keep their used state when the same code is still listed.
  - Deleting a secret: `deleteSecret` (`delete_secret.dart`) confirms with the shared `DestructiveDialog` (`widgets/destructive_dialog.dart`, also used by `DeleteVaultFileDialog`), then `save(vault, (p) => p.withoutSecret(id))`. Conflicts and failures are reported in a snack bar.
  - Creating secrets: the unlocked file pane's "New secret" FAB opens a `MenuAnchor` of `SecretType`s, then `showSecretEditor` (`secret_editor.dart`). The editor is full screen below 600dp; otherwise it's a dialog up to 560dp wide that sizes to its content (a min-size `Column` with a fixed-height, transparent `AppBar`, not a `Scaffold`). It has Close, the title, and Save in its header, and uses compact density with dense inputs, hints instead of helper lines, and 12dp gaps.
    - Always visible: the title (required), then the type fields via an exhaustive `switch` on `SecretType`: password (required for `PasswordSecret`, with generate and reveal), login (username/password/URL/TOTP), PEM (must contain `-----BEGIN `), recovery codes (one per line), and note text.
    - Collapsed under "More options" (collapsed by default): tags (comma separated), notes, validity, and custom fields (label required, value, masked toggle, remove).
    - Validity is entered as **days** ("Valid for … days", digits only, 1–36500, empty means never expires; preset chips for 30/90/180/365). The resulting date is shown below the field. It's stored as an absolute `expiresAt` = now (`appClockProvider`) + days.
    - The collapsed section stays built (`Visibility(maintainState: true)`) so its fields still validate, and Save expands it when one of its fields is invalid. The form is a non-lazy `SingleChildScrollView` for the same reason. Passwords are stored exactly as typed; other single-line fields are trimmed.
    - Saving calls `putSecret` and shows a progress bar. Conflicts and failures are shown inline and can be retried. On success it opens the new secret.
  - `CurrentLocation` closes an open secret when its file gets locked, from any source.
  - `widgets/`: shared widgets such as `MessageView`.
- Navigation is state, not routes. `currentLocationProvider` (keep-alive, IDs only) holds an `AppLocation` (storageId → filePath → secretId), and its `level` is the deepest open `AppLevel`. Panes call `openStorage`/`openFile`/`openSecret`/`up` on its notifier and highlight the open item with `ListTile.selected`. Removing the open storage resets the location. `AppShell` renders the panes for the location, so resizing the window never loses what is open.
- Riverpod 3 retries failing providers automatically. Providers that read storages opt out with `@Riverpod(retry: _noRetry)` and their screens offer Retry/Refresh instead. In tests, keep an auto-dispose provider alive with `container.listen` while awaiting its `.future`.

### Localization
- The app uses Flutter's `gen-l10n` (`flutter_localizations` + `intl`, `generate: true`, `apps/satchel/l10n.yaml`). English only for now.
- Strings live in `apps/satchel/lib/l10n/app_en.arb`. Every message needs an `@key` description (`required-resource-attributes: true`); use ICU plurals for counts and placeholders for values.
- `AppLocalizations` is generated into `lib/l10n/app_localizations*.dart` (gitignored) by `flutter pub get` from the root, or by `flutter gen-l10n`/`run`/`test`/`build`.
- Widgets get strings with `context.l10n.<key>` (extension in `lib/src/l10n/l10n.dart`, which re-exports `AppLocalizations`). Never hard-code user-facing text, including tooltips, snack bars and validator messages.
- Store state as data and localize in `build` (e.g. a `_failed` flag, not an error string).
- `SatchelApp` sets `localizationsDelegates`, `supportedLocales` and `onGenerateTitle`. Widget tests wrap screens in `testApp(...)` (`test/test_app.dart`); plain tests use `lookupAppLocalizations(const Locale('en'))`.
- Packages stay locale-free. `StorageProviderKind.defaultDisplayName` is only an English fallback, so the app shows built-in storages with `storageName`/`storageKindName` (`storage_display.dart`).
- To add a language, add `app_<locale>.arb`; `supportedLocales` follows automatically.

### UX structure (Material 3)
- Use stock **Material 3** widgets and theming only. No custom design system and no third-party UI kits. Theme comes from one fixed `ColorScheme.fromSeed` brand color (light + dark, following the system setting). Don't use Android dynamic color.
- **Adaptive layout:** one pane per level (Storages | Files | Secrets | Secret), side by side, like Miller columns. It's built with `LayoutBuilder` (no adaptive-scaffold package). `paneCountForWidth` maps M3 window size classes to a pane count: compact (< 600dp) 1, medium (600–840dp) 2, expanded (840–1200dp) 3, large (≥ 1200dp) 4. `visibleLevels` shows the current level plus the next one as an empty "Select a …" placeholder, and hides the top levels first when they don't fit. `paneWidthFor` gives every pane the same fixed width, 1/pane-count of the window (100%, 50%, 33% or 25%, minus dividers), and the last shown pane expands to fill the rest when fewer panes are shown. Inside `SecretPane` the fields are capped at `secretPaneMaxWidth` (560dp) and aligned to the start, so actions stay next to their values.
  - When the first visible pane's parent is hidden, that pane shows a back button. System back (`PopScope`) also moves up one level at any width.
  - Panes are `Scaffold`s nested in the shell's `Scaffold`, so snack bars appear once, at the shell level.
- **Routing:** `go_router`, with URLs mirroring the hierarchy (`/s/:providerId/f/:fileId/:secretId`). URLs carry IDs only, never secret data. A locked file's pane is its unlock screen, and the location never shows a secret of a locked file. Unlocked state is never restored from the URL or browser history.
- Several files can be unlocked at once (move/copy needs both ends unlocked). The files pane shows each file's lock state. "Lock all" and auto-lock lock every file and close any open detail view.
- Search defaults to the current file and can be switched to all unlocked files. It filters by type and tag.
- Screens: first run, add storage, storages & files, create file, unlock (password + extra KDF inputs, PIN on Android), secret list, secret detail, secret editor, move/copy destination picker, merge review, import/export, settings.
- Secret detail and editor views `switch` exhaustively on the sealed secret type:
  - Password: masked, reveal, copy, and a password generator in the editor (`generatePassword` in `satchel_core`: 20 characters by default from all four classes, at least one of each, without ambiguous `I l 1 O 0`, using `Random.secure()`).
  - Login: copyable username, masked password, URL that opens in the browser.
  - PEM: monospace, collapsed, save as file, and masked when it contains a private key.
  - Recovery codes: checklist of used/unused codes with an "N left" count and a low-count warning.
  - Note: multi-line, masked.
  - Every type shows tags, the expiry, and created/updated timestamps.
- Merge review groups items as new / identical (collapsed) / conflict / possible duplicate. Each item gets a `SegmentedButton` (Keep incoming / Keep existing / Keep both / Skip) plus "apply to all". Nothing is written until the user presses Confirm.
- Desktop/web:
  - Keyboard shortcuts via `Shortcuts`/`Actions`: `Ctrl+F` search, `Ctrl+N` new secret, `Ctrl+L` lock all, `Ctrl+B` copy username, `Ctrl+Shift+C` copy password.
  - Right-click context menus with `MenuAnchor`.
  - Dragging secrets between files starts move/copy.
- Android: swipe actions on list items and bottom-sheet pickers.

### Data hierarchy: Provider → File → Secret
- **StorageProvider**: a configured storage location (e.g. "Local", "Google Drive – personal"). Lists, reads, and writes opaque encrypted blobs. It never sees plaintext. Providers expose a `ProviderSecurityProfile` that tells the unlock flow which extra KDF inputs it supports or requires.
- **Vault file**: one encrypted file within a provider, each with its own password. It's the unit of encryption, sync, and import/export. Carries a stable `fileId` (UUID), `name`, `createdAt`, and `updatedAt`.
- **Secret** (`satchel_core`, `secret.dart` + `secret_info.dart`): an entry inside a vault file, modeled as an immutable `sealed class Secret` with these variants:
  - `PasswordSecret` (`password`).
  - `LoginSecret` (`username`, `password`, a single `url`, and `totp`, an otpauth URI or base32 seed stored as entered).
  - `PemSecret` (`pem`; `containsPrivateKey` tells the UI to mask it).
  - `RecoveryCodesSecret` (`codes`: `RecoveryCode(code, used:)`, plus `remaining` and `withCodeUsed`).
  - `NoteSecret` (`text`, masked).
- Every variant shares a `SecretInfo` (exposed through getters on `Secret`): `id` (UUID), `title`, `tags`, `createdAt`, `updatedAt`, optional `expiresAt`, free-text `notes`, and `customFields` (`CustomField(label, value, concealed:)`). Empty strings mean "not set". Only `expiresAt` is nullable; clear it with `copyWith(expiresAt: () => null)`. Tags are normalized (trimmed, deduplicated ignoring case, sorted). The UI switches exhaustively on the sealed type, so adding a variant forces every editor/view to handle it.
- Edit with a variant's `copyWith`/`withInfo`, then `Secret.applyEdit(original, edited, clock:)`. It keeps the id and `createdAt`, sets `updatedAt` only if `sameContentAs` says the content changed, and otherwise returns the original. `sameContentAs` compares everything except the id and timestamps. `==` compares everything. `duplicate()` gives a new id and new timestamps (for "duplicate in the same file" only). `expiryStatus(now)` returns `none`/`valid`/`expiringSoon` (default 30 days)/`expired`.
- `VaultPayload.secrets` is a `List<Secret>` with unique ids. `withSecret` (add, or replace in place), `withoutSecret` and `withName` bump the file's `updatedAt` and return the same instance when nothing changes. `secretById` looks a secret up.

### Timestamps
- Both files and secrets have **required** `createdAt` and `updatedAt`. They're stored in UTC as ISO-8601 strings and shown in local time.
- File timestamps live **inside the encrypted payload**, not in the plaintext header. Never rely on provider or filesystem mtime for them.
- `createdAt` is set once and never changes. `updatedAt` changes only when content changes. Editing a secret bumps both the secret's and its file's `updatedAt`. Adding, removing, or merging secrets bumps the file's `updatedAt`.
- Move, copy, and import **preserve** a secret's original `createdAt`/`updatedAt`. They describe the secret, not where it's stored.
- Domain code gets the time from an injected `Clock`, never `DateTime.now()` directly, so tests can be deterministic.

### Vault file format (`satchel_core`)
- Vault files are named `<name>.satchel` in every storage (`vaultFileExtension`, `isVaultFileName`, `vaultNameFromPath`, `vaultPathForName` in `vault_format.dart`). Other blobs are ignored when listing. `checkVaultName` defines the names that are portable file names everywhere (no `<>:"/\|?*` or control characters, no leading dot, no trailing dot or surrounding spaces, no Windows device names, at most 100 characters). The directory provider and the "New file" dialog both use it.
- Binary layout (v1, `VaultCodec` in `vault_codec.dart`): `"SATCHEL\0" (8) | formatVersion (u16 BE) | header length (u32 BE) | header (UTF-8 JSON) | ciphertext | GCM tag (16)`.
- The header is `{"kdf": {"algorithm": "argon2id", "memoryKiB", "iterations", "parallelism", "salt"}, "extraInputs": [ids], "cipher": "aes-256-gcm", "nonce"}`, with base64 for the salt and nonce. `extraInputs` lists the ids of the extra KDF inputs used (keyfile, provider secret, …).
- **Everything before the ciphertext (magic, version, length, and header) is the AES-GCM AAD**, so tampering with params or flags fails decryption. KDF params are bounds-checked (`KdfParams.validate`) before deriving a key, so a crafted header can't exhaust memory.
- The plaintext payload (`VaultPayload`) is a JSON document: `{"version": 1, "fileId", "name", "createdAt", "updatedAt", "secrets": [...]}`. Timestamps are UTC ISO-8601, truncated to milliseconds everywhere (`utcMillis`) so the VM and the web write identical files.
- Each secret is a flat object: `{"type": <SecretType name>, "id", "title", "createdAt", "updatedAt", ["tags"], ["expiresAt"], ["notes"], ["customFields": [{"label", "value", "concealed"}]], ...type fields}`. Optional common fields are omitted when unset. Type fields are always written (`password`; `username`/`password`/`url`/`totp`; `pem`; `codes: [{"code", "used"}]`; `text`). `SecretType` names are stored values, so never rename them. Unknown types, wrong field types and duplicate ids throw `VaultFormatException`, whose message names only the field, never the value.
- KDF (`KeyDerivation` in `kdf.dart`): Argon2id over the 4-byte-big-endian-length-prefixed UTF-8 password, followed by each extra input's id and bytes in id order, also length-prefixed. The output is a 32-byte key. Never use plain concatenation.
- `VaultKey` holds the derived key plus its params, so an unlocked vault can be re-saved with `VaultCodec.encrypt` without re-running the KDF. `VaultCodec.decrypt` derives the key and returns an `OpenedVault`, and `decryptWithKey` verifies a write. Call `VaultKey.destroy()` (which zeroes it) when done. Failures form a sealed `VaultException` family: `VaultFormatException`, `UnsupportedVaultVersionException`, `MissingKdfInputException`, and `VaultAuthenticationException` (wrong password or tampering, which GCM can't tell apart).
- Every write generates a **fresh random 96-bit nonce** (and keeps the salt unless the password changes). Never reuse a nonce with the same key.
- Use the `cryptography` package (`Argon2id`, `AesGcm`). On native platforms, add `cryptography_flutter` for acceleration. Don't hand-roll primitives.
- KDF params are stored per file, and **any file must be openable on the slowest platform (web)**. The defaults follow OWASP's Argon2id recommendation, m=46 MiB (47104 KiB), t=1, p=1. That's about 0.8–1 s in Chrome (dart2js and dart2wasm) and about 0.16 s on the Dart VM. Higher settings (e.g. 64 MiB × 3) took about 3.5 s on the web.

### Storage providers (`satchel_storage`)
- Contract (`StorageProvider` in `lib/src/storage_provider.dart`): providers deal only in opaque encrypted bytes, and every blob carries an opaque `revision`. `write(path, bytes, expectedRevision:)` is **conditional**: `null` means "create, must not exist", and otherwise the value must equal the current revision. `delete` also requires the current revision. Mismatches throw `StorageConflictException`, missing blobs throw `StorageNotFoundException`, and backend failures (storage disabled, quota, …) throw `StorageBackendException` (a sealed `StorageException` family). There is deliberately no unconditional overwrite. A revision must change whenever the content changes, so a stale revision never matches different content (identical content may share a revision, e.g. content hashes).
- The shared contract suite `storageProviderContractTests` in `test/storage_provider_contract.dart` defines these semantics. Every provider must run it (see `test/indexed_db_storage_provider_test.dart` and `test/directory/`).
- Platform availability: `StorageProviderKind` (in `lib/src/storage_provider_kind.dart`) lists each implemented kind with the `StoragePlatform`s it supports. Use `kind.isSupported` / `StorageProviderKind.supportedOn(platform)` before offering a kind, and `kind.create(StorageConfig)` to construct it. `userAddable` kinds are added by the user (possibly several), and the rest are built in. Add every new provider there and handle it in the app's exhaustive `switch`es. Platform-specific implementations are selected with a conditional export (`if (dart.library.js_interop)` / `if (dart.library.io)`) and a stub that compiles everywhere but throws `UnsupportedError`, so the package builds on every target. Never import `dart:io`, `dart:ffi`, or the SAF plugins from code reachable on web.
- Web: `IndexedDbStorageProvider` (kind `indexedDb`, web only) uses `package:web` + `dart:js_interop` (works with dart2js and dart2wasm). There's one IndexedDB database per provider id (`satchel_storage.<id>`) with an `entries` store (path + revision) and a `blobs` store (bytes). Each conditional write or delete is a single read-compare-write transaction driven from the IndexedDB request callbacks rather than `await`, so the transaction stays active and revision checks hold across tabs. Its tests are `@TestOn('browser')`.
- Directory (kind `directory`, Android/Linux/Windows, user-added, several allowed): `DirectoryStorageProvider` stores each blob as `<name>.satchel` in a user-chosen folder. It lists only valid `*.satchel` names, and paths must be plain file names (no separators or leading dot). The revision is the SHA-256 of the contents, recomputed on each access, so changes by sync tools or other apps surface as conflicts. Conditional writes re-read the file just before writing, and operations on the same folder are serialized within the app. Raw I/O sits behind `DirectoryBackend`, chosen from the location by `directoryBackendFor`:
  - Desktop (`IoDirectoryBackend`, `dart:io`): write to a hidden temp file, flush, then rename over the target (atomic). The folder is picked with `file_selector`.
  - Android (`SafDirectoryBackend`, `saf_util` + `saf_stream`): the location is a Storage Access Framework tree URI picked with a persisted read/write permission. SAF has no atomic replace, so a write goes to a hidden temp file, then the old file is deleted and the temp one renamed. A crash in between leaves the new data in `.<name>.<random>.tmp`, never lost.
  - Tests: `test/directory/` (VM only) runs the contract against a real temp dir and against fake SAF platform interfaces. `saf_stream` pulls in `package:jni`, which is why web builds must never reach that code.
- On web, local storage is the IndexedDB provider above. Export downloads files (`FileExporter`); upload is not yet implemented.
- Google Drive: called directly from the client via Drive v3 REST, with minimal scope (`drive.file`) and no server. Sign-in uses `google_sign_in` on Android and web. It has no Linux/Windows support, so desktop uses the OAuth installed-app loopback flow with PKCE (e.g. `googleapis_auth`). Keep both behind one auth interface.
- Offline: remote providers keep a locally cached **encrypted** copy. Writes check the remote revision/etag. On a mismatch they go through the same merge flow as move/copy/import (see below) instead of silently overwriting.

### PIN unlock (optional, Android, `apps/satchel`)
- A 6–8 digit PIN is low entropy and must never be the sole protection of a stored file password.
- The file password (or derived key) is encrypted with a key derived from **PIN + a random device secret held in platform secure storage** (`flutter_secure_storage` → Android Keystore). The PIN option is offered on Android only.
- Failed attempts are counted. After N failures, the PIN-wrapped material is wiped and the full password is required.

### Import / export
- Export works on an unlocked file only, either the selected secrets (selection mode in `SecretsPane`) or all of them ("Export" in the file's menu). `exportSecrets` (`lib/src/export/export_secrets.dart`) opens `ExportSecretsDialog`, which offers Encrypted or Plain JSON, then saves through `fileExporterProvider`. The snack bar names the saved file. If the user cancels the save dialog, the export dialog stays open.
- Exports keep the vault's `fileId`, name, timestamps and secret ids (`VaultPayload.withOnlySecrets`), so importing them later merges instead of duplicating. They're named `<name>.satchel` or `<name>.json`.
- Encrypted export (`UnlockedVaults.exportEncrypted`) writes a standard vault file under the session key with a fresh nonce, or under a different password with a new salt.
- Unencrypted export (`UnlockedVaults.exportPlain` → `PlainExport.encode`, `{"satchelExport": 1, "vault": <payload>}`) shows a warning and stays disabled until the user ticks the acknowledgment. Its bytes are zeroed after saving. It's the only code path allowed to write plaintext secrets anywhere.
- `FileExporter` (`satchel_storage`, `createPlatformFileExporter`) saves outside any storage. Desktop uses the `file_selector` save dialog. Android has the user pick a folder (SAF, no persisted permission) and never overwrites. Web downloads through a blob URL.
- Selection mode starts with a long press or "Select" in a row's menu. Taps then toggle checkboxes, and the app bar shows the count, Select all, Clear selection and an Export button instead of Lock and the New secret FAB. The selection holds ids only, drops deleted secrets, and clears on lock, on a successful export, or when another file opens.
- Import works on an unlocked file only ("Import" in the file's menu) and always goes through the merge flow below. `importSecrets` (`lib/src/import/import_secrets.dart`) picks a file through `fileImporterProvider` (`FileImporter`/`FileSelectorImporter` in `satchel_storage`, `file_selector` on every platform, unfiltered on Android, which can't map `.satchel` to a MIME type). `UnlockedVaults.readImport` detects the format by extension, ignoring case: `.json` is a plain export, and `.satchel` is a vault file. A vault file is first tried with the destination's session key (its own exports), else `ImportPasswordDialog` asks for its password. Other extensions throw `UnsupportedImportException`. The picked bytes are zeroed afterwards.
- `ImportReviewDialog` shows the counts of new and identical secrets and lists each conflict with both versions (title and `updatedAt`, the newer one marked and pre-selected), with Keep all current/Use all imported. Nothing is written until Import (`UnlockedVaults.applyImport` → `save`). Cancelling changes nothing.

### Move / copy between storages
- Files and secrets can be moved or copied to any provider or file: a whole file (provider → provider), or individual secrets (file → file, within or across providers).
- Copying or moving a **file** keeps its `fileId` and its secrets' `id`s. That way, copying it back later or importing its export is detected as the same data and merged rather than duplicated. A copied file is re-encrypted under the destination's KDF and password settings, with a new salt and nonce.
- Copying or moving a **secret** keeps its `id` and timestamps. The only exception is "duplicate in the same file", which gets a new `id` and new timestamps.
- Cross-file operations need **both files unlocked**. Secrets are decrypted with the source key and re-encrypted with the destination key in memory. Plaintext is never staged on disk.
- **A move is copy → verify → delete.** Write the destination, re-read and decrypt it to verify, and only then remove from the source. If any step fails, the source stays intact. Partial failures leave data duplicated, never lost.

### Merge and conflict resolution
- Import, move, copy, and sync conflicts all share **one merge pipeline**:
  1. `satchel_core` builds a `MergePlan` with a pure function: `planMerge(source, destination) → MergePlan`, with no I/O and no UI.
  2. The app shows the plan to the user.
  3. The user resolves each conflict and confirms.
  4. `applyMerge(plan, resolutions)` produces the new payload, which is then written.
- Matching is by `id` (secrets) and `fileId` (files). For each secret, the plan classifies it as:
  - **new**: only in the source. It's added.
  - **identical**: same id and same content. Not a conflict; it's skipped.
  - **conflict**: same id, different content.
  - **possible duplicate**: different id but the same type, title, and username/URL.
- Conflict resolutions per item are: keep source, keep destination, keep both (the source copy gets a new `id`), or skip. Also offer "apply to all". Implemented so far (`merge.dart`): new, identical and conflict, resolved with `ConflictResolution.keepExisting`/`useIncoming`. `applyMerge(destination, plan, resolutions)` throws on an unresolved conflict and keeps merged secrets' own timestamps.
- The newer `updatedAt` may be **pre-selected as a suggestion**, but nothing is applied without explicit user confirmation. Never auto-resolve silently, even when timestamps differ.
- The confirmation screen shows a side-by-side diff of the fields that changed, with secret values masked until the user reveals them, plus both timestamps.
- Cancelling at any point leaves both source and destination unchanged.

## Conventions

- **Crypto and format code lives only in `satchel_core`.** UI and storage code call its high-level API (`VaultCodec.encrypt/decrypt`, `KeyDerivation`) and never touch primitives directly.
- **Any format change bumps `formatVersion`** and must keep decryption support for all previous versions. `satchel_core/test` holds committed golden vault files and known-answer test vectors per version (`test/golden/v1/*.satchel`, with their inputs in `test/golden_inputs.dart`; `secrets.satchel` holds one secret of every type from `test/secret_fixtures.dart`, which must never change). Encrypting the inputs must reproduce each file byte for byte. Never regenerate an existing golden; add new ones for each new version. The v1 goldens and the Argon2id KAT in `kdf_test.dart` were cross-checked with Python's `argon2-cffi` and `cryptography`.
- Crypto tests must cover the negative cases: wrong password, missing extra KDF input, tampered header, tampered ciphertext, and an unknown version.
- `planMerge`/`applyMerge` tests cover every classification and resolution. Move tests cover failure at each step (write, verify, delete) and check that the source is never lost.
- Never log, `print`, `toString()`, or include in exceptions any secret value, password, PIN, or key. Secret models override `toString()` to redact.
- Zero key and password `Uint8List` buffers after use (`fillRange(0, len, 0)`) wherever the API allows.
- Plaintext never touches disk, cache, or shared prefs. Persist encrypted bytes only.
- UI hygiene for secrets: values are masked by default, the clipboard is auto-cleared after a timeout, and screen capture is blocked and app-switcher previews hidden on Android (`FLAG_SECURE`). The vault auto-locks after inactivity or when the app is backgrounded.
- No network calls other than the user's configured storage providers. No analytics or telemetry.
- Expiration: `expiresAt` is optional. The UI highlights secrets that are expired or about to expire in list and detail views. `ExpiryHighlight.of(context, secret, now)` (`secrets/expiry_display.dart`) is the single source of that styling. It returns `null` unless the status is expired or expiring soon (30 days), and otherwise provides the icon (`event_busy`/`schedule`), relative text from calendar days in local time (`daysUntil` → "Expires today/tomorrow/in N days", "Expired today/yesterday/N days ago"), and colors from the `ColorScheme` (expired: error / errorContainer / onErrorContainer; soon: tertiary / tertiaryContainer / onTertiaryContainer).
  - List rows (`_SecretTile`) use the container color as `tileColor` and `selectedTileColor` (so selection keeps the tint), `onContainer` for text and icons, and a subtitle with the icon and relative text. Never signal expiry by color alone.
