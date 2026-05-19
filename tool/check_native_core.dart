import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keytitan/native_core.dart';

void main() {
  final core = KeyTitanNativeCore.instance;
  if (core == null) {
    throw StateError('keytitan_core native library was not loaded');
  }

  final password = Uint8List.fromList(utf8.encode('test-master-password'));
  final encryptedField = core.fieldEncrypt(password, 'test-entry-password');
  if (encryptedField == null) {
    throw StateError('field encryption failed');
  }

  final decryptedField = core.fieldDecrypt(password, encryptedField);
  if (decryptedField != 'test-entry-password') {
    throw StateError('field decryption mismatch');
  }

  final sqliteBytes = Uint8List.fromList([
    ...utf8.encode('SQLite format 3\u0000'),
    ...List<int>.filled(128, 0),
  ]);
  final encryptedVault = core.encryptVault(sqliteBytes, password);
  if (encryptedVault == null) {
    throw StateError('vault encryption failed');
  }

  final decryptedVault = core.decryptVault(encryptedVault, password);
  if (decryptedVault == null ||
      decryptedVault.length != sqliteBytes.length ||
      !const ListEquality().equals(decryptedVault, sqliteBytes)) {
    throw StateError('vault decryption mismatch');
  }

  final derivedUris = core.deriveUris('https://amazon.com/login');
  if (derivedUris == null ||
      !derivedUris.contains('https://amazon.com') ||
      derivedUris.contains('androidapp://')) {
    throw StateError('URI derivation mapping mismatch');
  }

  password.fillRange(0, password.length, 0);
  encryptedVault.fillRange(0, encryptedVault.length, 0);
  decryptedVault.fillRange(0, decryptedVault.length, 0);
  sqliteBytes.fillRange(0, sqliteBytes.length, 0);

  stdout.writeln('keytitan_core FFI check passed');
}

class ListEquality {
  const ListEquality();

  bool equals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}
