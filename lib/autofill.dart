import 'package:flutter/services.dart';
import 'globals.dart';

typedef AutofillPasswordResolver = Future<String?> Function(String entryId);

class KeyTitanAutofillBridge {
  static const _channel = MethodChannel('app.keytitan/autofill');
  static AutofillPasswordResolver? _passwordResolver;
  static bool _handlerInstalled = false;

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
        'enabled': enabled,
        'attemptWindowSeconds': attemptWindowSeconds,
      },
    );
  }

  static Future<void> updateEntries({
    required List<Map<String, Object?>> entries,
    required int attemptWindowSeconds,
  }) async {
    if (!Constants.isMobile) return;
    await _invoke(
      'updateEntries',
      {
        'entries': entries,
        'attemptWindowSeconds': attemptWindowSeconds,
      },
    );
  }

  static Future<void> clearEntries() async {
    if (!Constants.isMobile) return;
    await _invoke('clearEntries');
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
    if (rawId == null || rawId.isEmpty) return null;
    return _passwordResolver?.call(rawId);
  }
}
