import 'dart:async';

import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'secret_clipboard.g.dart';

/// Copies secret values and clears the clipboard again after [clearAfter],
/// unless something else was copied in the meantime.
final class SecretClipboard {
  SecretClipboard({this.clearAfter = const Duration(seconds: 30)});

  final Duration clearAfter;
  Timer? _timer;

  Future<void> copy(String value) async {
    _timer?.cancel();
    await Clipboard.setData(ClipboardData(text: value));
    _timer = Timer(clearAfter, () => unawaited(_clear(value)));
  }

  Future<void> _clear(String value) async {
    _timer = null;
    String? current;
    try {
      current = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      // Reading may be refused (e.g. by the browser): clear anyway, the value
      // we copied is most likely still there.
      current = value;
    }
    if (current == value) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  void dispose() => _timer?.cancel();
}

@Riverpod(keepAlive: true)
SecretClipboard secretClipboard(Ref ref) {
  final clipboard = SecretClipboard();
  ref.onDispose(clipboard.dispose);
  return clipboard;
}
