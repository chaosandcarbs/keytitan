import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/autofill.dart';
import 'package:keytitan/settings.dart';

void main() {
  test('clipboard label is explicit without changing stored preferences', () {
    expect(PasswordOutputMode.clipboard.label, 'Clipboard Only');
    expect(PasswordOutputMode.clipboard.storageValue, 'clipboard');
    expect(PasswordOutputMode.fromStorage('clipboard'),
        PasswordOutputMode.clipboard);
  });
  test(
      'Android autofill is independent of clipboard output and persists opt-out',
      () {
    final defaults =
        KeyTitanSettingsData.fromJson(const {'outputMode': 'clipboard'});
    expect(defaults.androidAutofillEnabled, isTrue);
    final disabled = defaults.copyWith(androidAutofillEnabled: false);
    expect(
        KeyTitanSettingsData.fromJson(disabled.toJson()).androidAutofillEnabled,
        isFalse);
  });
  test('autofill is unavailable on desktop platforms', () {
    if (Platform.isAndroid || Platform.isIOS) return;

    expect(KeyTitanAutofillBridge.isAvailable, isFalse);
    expect(
      KeyTitanSettingsData.fromJson(const {'outputMode': 'autofill'})
          .outputMode,
      PasswordOutputMode.clipboard,
    );
  });

  test('desktop autofill preferences persist as clipboard mode', () {
    if (Platform.isAndroid || Platform.isIOS) return;

    final encoded = const KeyTitanSettingsData(
      outputMode: PasswordOutputMode.autofill,
    ).toJson();

    expect(encoded['outputMode'], PasswordOutputMode.clipboard.storageValue);
  });
}
