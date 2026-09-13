import 'dart:io';

import 'package:flutter/services.dart';
import 'globals.dart';

typedef AutofillPasswordResolver = Future<String?> Function(
  String entryId,
  String vaultId,
  String sessionEpoch,
);

class KeyTitanAutofillBridge {
  static const _channel = MethodChannel('app.keytitan/autofill');
  static AutofillPasswordResolver? _passwordResolver;
  static bool _handlerInstalled = false;

  static bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  static Future<void> rememberVault(String path) async {
    if (Platform.isAndroid) await _invoke('rememberVault', {'path': path});
  }

  static Future<Map<Object?, Object?>> status() async =>
      await _channel.invokeMapMethod<Object?, Object?>('status') ?? {};

  static Future<void> enableService() => _invoke('enableService');

  static void setPasswordResolver(AutofillPasswordResolver? resolver) {
    _passwordResolver = resolver;
    if (!_handlerInstalled) {
      _channel.setMethodCallHandler(_handleNativeCall);
      _handlerInstalled = true;
    }
  }

  static Future<void> configure({
    required bool enabled,
    required int attemptWindowSeconds,
  }) async {
    if (!Constants.isMobile) return;
    await _invoke(
      'configure',
      {
        'enabled': enabled && isAvailable,
        'attemptWindowSeconds': attemptWindowSeconds,
      },
    );
  }

  static Future<void> updateEntries({
    required List<Map<String, Object?>> entries,
    required int attemptWindowSeconds,
    required String vaultId,
    required String sessionEpoch,
  }) async {
    if (!Constants.isMobile) return;
    if (!isAvailable) {
      await clearEntries();
      return;
    }
    await _invoke(
      'updateEntries',
      {
        'entries': entries,
        'attemptWindowSeconds': attemptWindowSeconds,
        'vaultId': vaultId,
        'sessionEpoch': sessionEpoch,
      },
    );
  }

  static Future<void> clearEntries() async {
    if (!Constants.isMobile) return;
    await _invoke('clearEntries');
  }

  static Future<void> clearTrust() async {
    if (!Platform.isAndroid) return;
    await _invoke('clearTrust');
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // Some platforms/builds do not include a native autofill bridge.
    }
  }

  static Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'resolvePassword') {
      throw MissingPluginException();
    }

    final args = call.arguments;
    final rawId = args is Map ? args['id']?.toString() : null;
    final vaultId = args is Map ? args['vaultId']?.toString() : null;
    final sessionEpoch = args is Map ? args['sessionEpoch']?.toString() : null;
    if (rawId == null ||
        rawId.isEmpty ||
        vaultId == null ||
        vaultId.isEmpty ||
        sessionEpoch == null ||
        sessionEpoch.isEmpty) {
      return null;
    }
    return _passwordResolver?.call(rawId, vaultId, sessionEpoch);
  }
}
