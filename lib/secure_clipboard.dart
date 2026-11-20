import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';

import 'sensitive.dart';

class SensitiveClipboard {
  static const _channel = MethodChannel('app.keytitan/security');
  static Timer? _expiry;
  static int _generation = 0;

  static Future<void> copy(String password, {Duration? clearAfter}) async {
    _expiry?.cancel();
    final generation = ++_generation;
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('copySensitive', {
        'text': password,
        'clearAfterMs': clearAfter?.inMilliseconds,
      });
    } else {
      await Clipboard.setData(ClipboardData(text: password));
      if (clearAfter != null && generation == _generation) {
        final bytes = utf8.encode(password);
        try {
          _scheduleExpiry(
            generation,
            clearAfter,
            sha256.convert(bytes).toString(),
          );
        } finally {
          wipeBytes(bytes);
        }
      }
    }
  }

  // This closure captures only the generation and digest, never the password.
  static void _scheduleExpiry(int generation, Duration delay, String digest) {
    _expiry = Timer(
      delay,
      () => unawaited(_clearOwnedClip(generation, digest)),
    );
  }

  static Future<void> _clearOwnedClip(int generation, String digest) async {
    try {
      final text = (await Clipboard.getData('text/plain'))?.text;
      if (text == null || generation != _generation) return;
      final bytes = utf8.encode(text);
      try {
        if (sha256.convert(bytes).toString() == digest) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } finally {
        wipeBytes(bytes);
      }
    } on PlatformException {
      // Clipboard access can disappear during shutdown or a platform lock.
    }
  }
}
