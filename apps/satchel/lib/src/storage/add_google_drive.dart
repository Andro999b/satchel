import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:satchel_storage/satchel_storage.dart';

import '../accounts/google_account_avatar.dart';
import '../accounts/google_accounts.dart';
import '../l10n/l10n.dart';
import '../navigation/app_location.dart';
import 'storage_providers.dart';

/// What [AddGoogleDriveDialog] chose.
typedef DriveStorageChoice = ({
  GoogleAccount account,
  String folderId,
  String folderPath,
  String name,
});

/// Lets the user choose an account and a Drive folder, then adds the storage
/// and opens it.
Future<void> addGoogleDrive(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(storageConfigsProvider.notifier);
  final location = ref.read(currentLocationProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final choice = await showDialog<DriveStorageChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AddGoogleDriveDialog(),
  );
  if (choice == null) return;
  try {
    final config = await notifier.add(
      kind: StorageProviderKind.googleDrive,
      displayName: choice.name,
      location: choice.folderId,
      locationName: choice.folderPath,
      accountId: choice.account.id,
    );
    location.openStorage(config.id);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.addDriveError)));
  }
}

enum _Step { account, folder, name }

enum _DriveError {
  signInFailed,
  driveDenied,
  loadFolders,
  createFolder,
  alreadyAdded,
}

/// Three steps: the Google account, a folder in its Drive (only folders
/// Satchel created are visible), and the storage name. Pops a
/// [DriveStorageChoice], or `null` if cancelled.
class AddGoogleDriveDialog extends ConsumerStatefulWidget {
  const AddGoogleDriveDialog({super.key});

  @override
  ConsumerState<AddGoogleDriveDialog> createState() =>
      _AddGoogleDriveDialogState();
}

class _AddGoogleDriveDialogState extends ConsumerState<AddGoogleDriveDialog> {
  var _step = _Step.account;
  GoogleAccount? _account;
  DriveFolderSource? _source;

  /// Folders from "My Drive" down to the current one.
  final _path = <DriveFolder>[];

  /// Folders in the current folder; `null` while loading or after an error.
  List<DriveFolder>? _folders;
  var _busy = false;
  _DriveError? _error;
  late final _name = TextEditingController();

  String get _folderId => _path.lastOrNull?.id ?? driveRootFolderId;

  String _pathText(AppLocalizations l10n) =>
      [l10n.driveMyDrive, for (final folder in _path) folder.name].join(' / ');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _chooseAccount(GoogleAccount account) {
    _account = account;
    _source = ref.read(driveFolderSourceProvider)(account);
    _path.clear();
    setState(() => _step = _Step.folder);
    _load();
  }

  Future<void> _addAccount() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _DriveError? error;
    GoogleAccount? account;
    try {
      account =
          (await ref.read(googleAccountsProvider.notifier).add())?.account;
    } on GoogleDriveAccessDeniedException {
      error = _DriveError.driveDenied;
    } catch (_) {
      error = _DriveError.signInFailed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (account != null) _chooseAccount(account);
  }

  Future<void> _load() async {
    final source = _source!;
    final folderId = _folderId;
    setState(() {
      _folders = null;
      _error = null;
    });
    _DriveError? error;
    List<DriveFolder>? folders;
    try {
      folders = await source.list(folderId);
    } on StorageAuthRequiredException {
      error = _DriveError.signInFailed;
    } catch (_) {
      error = _DriveError.loadFolders;
    }
    if (!mounted || folderId != _folderId || source != _source) return;
    setState(() {
      _folders = folders;
      _error = error;
    });
  }

  void _open(DriveFolder folder) {
    _path.add(folder);
    _load();
  }

  void _up() {
    _path.removeLast();
    _load();
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderDialog(),
    );
    if (name == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final folder = await _source!.create(_folderId, name);
      if (!mounted) return;
      setState(() => _busy = false);
      _open(folder);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is StorageAuthRequiredException
            ? _DriveError.signInFailed
            : _DriveError.createFolder;
      });
    }
  }

  Future<void> _useFolder() async {
    final l10n = context.l10n;
    final taken = await ref
        .read(storageConfigsProvider.notifier)
        .hasLocation(_folderId, accountId: _account!.id);
    if (!mounted) return;
    if (taken) {
      setState(() => _error = _DriveError.alreadyAdded);
      return;
    }
    _name.text = _path.lastOrNull?.name ?? l10n.storageKindGoogleDrive;
    setState(() {
      _error = null;
      _step = _Step.name;
    });
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop<DriveStorageChoice>(context, (
      account: _account!,
      folderId: _folderId,
      folderPath: _pathText(context.l10n),
      name: name,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cancel = TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(l10n.cancel),
    );
    return AlertDialog(
      title: Text(l10n.addDriveTitle),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...switch (_step) {
              _Step.account => _accountStep(l10n),
              _Step.folder => _folderStep(l10n),
              _Step.name => _nameStep(l10n),
            },
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              Text(switch (error) {
                _DriveError.signInFailed => l10n.googleSignInFailed,
                _DriveError.driveDenied => l10n.googleDriveAccessDenied,
                _DriveError.loadFolders => l10n.driveFoldersLoadError,
                _DriveError.createFolder => l10n.driveCreateFolderError,
                _DriveError.alreadyAdded => l10n.folderAlreadyAdded,
              }, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: switch (_step) {
        _Step.account => [
          cancel,
          TextButton.icon(
            onPressed: _busy ? null : _addAccount,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: Text(l10n.addGoogleAccount),
          ),
        ],
        _Step.folder => [
          cancel,
          TextButton.icon(
            onPressed: _busy || _folders == null ? null : _newFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: Text(l10n.driveNewFolder),
          ),
          FilledButton(
            onPressed: _busy || _folders == null ? null : _useFolder,
            child: Text(l10n.driveUseFolder),
          ),
        ],
        _Step.name => [
          TextButton(
            onPressed: () => setState(() => _step = _Step.folder),
            child: Text(l10n.back),
          ),
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => FilledButton(
              onPressed: _name.text.trim().isEmpty ? null : _submit,
              child: Text(l10n.addFolderConfirm),
            ),
          ),
        ],
      },
    );
  }

  List<Widget> _accountStep(AppLocalizations l10n) {
    final accounts = ref.watch(googleAccountsProvider);
    return [
      Text(l10n.driveChooseAccount),
      const SizedBox(height: 8),
      accounts.when(
        data: (accounts) => accounts.isEmpty
            ? Text(
                l10n.driveNoAccounts,
                style: Theme.of(context).textTheme.bodySmall,
              )
            : Column(
                children: [
                  for (final account in accounts)
                    ListTile(
                      key: ValueKey(account.id),
                      contentPadding: EdgeInsets.zero,
                      leading: GoogleAccountAvatar(account: account),
                      title: Text(
                        account.displayName.isEmpty
                            ? account.email
                            : account.displayName,
                      ),
                      subtitle: account.displayName.isEmpty
                          ? null
                          : Text(account.email),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _chooseAccount(account),
                    ),
                ],
              ),
        error: (_, _) => Text(l10n.googleAccountsLoadError),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    ];
  }

  List<Widget> _folderStep(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final folders = _folders;
    final loadFailed =
        folders == null &&
        (_error == _DriveError.loadFolders ||
            _error == _DriveError.signInFailed);
    return [
      Row(
        children: [
          if (_path.isNotEmpty)
            IconButton(
              tooltip: l10n.driveUpTooltip,
              icon: const Icon(Icons.arrow_upward),
              onPressed: _busy ? null : _up,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_pathText(l10n), style: theme.textTheme.titleSmall),
                Text(_account!.email, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
      const Divider(),
      if (folders == null && !loadFailed)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (loadFailed)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retry),
          ),
        )
      else if (folders!.isEmpty) ...[
        Text(l10n.driveNoFolders, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(l10n.driveFoldersHint, style: theme.textTheme.bodySmall),
      ] else
        for (final folder in folders)
          ListTile(
            key: ValueKey(folder.id),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _open(folder),
          ),
    ];
  }

  List<Widget> _nameStep(AppLocalizations l10n) => [
    ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.add_to_drive),
      title: Text(_pathText(l10n)),
      subtitle: Text(_account!.email),
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _name,
      autofocus: true,
      decoration: InputDecoration(labelText: l10n.nameLabel),
      onSubmitted: (_) => _submit(),
    ),
  ];
}

/// Asks for the name of a new Drive folder. Pops the trimmed name.
class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  late final _controller = TextEditingController(text: 'Satchel');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.driveNewFolder),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.nameLabel),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: Text(l10n.driveCreateFolder),
          ),
        ),
      ],
    );
  }
}
