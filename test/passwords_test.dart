import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/passwords.dart';
import 'package:keytitan/vault_files.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('attemptDecrypt rejects non-KTN3 vault files', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/old-format.ktn');
    final vault = passFile(file.path, 'test-master-password');

    try {
      await file.writeAsBytes(List<int>.filled(25, 0));

      expect(await vault.attemptDecrypt(), isFalse);
    } finally {
      await vault.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('hdecrypt rejects unprefixed field ciphertext', () async {
    final password = Uint8List.fromList(utf8.encode('test-master-password'));

    try {
      expect(
        await keyTitanPass.hdecrypt(password, 'iv:ciphertext'),
        keyTitanPass.decryptionError,
      );
    } finally {
      password.fillRange(0, password.length, 0);
    }
  });

  test('vault filename validation only accepts safe ktn names', () {
    expect(KeyTitanVaultFiles.safeFileName('vault.ktn'), 'vault.ktn');
    expect(KeyTitanVaultFiles.safeFileName('../vault.ktn'), isNull);
    expect(KeyTitanVaultFiles.safeFileName('vault.pass'), isNull);
  });

  test('changeMasterPassword re-encrypts fields and saves vault', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/vault.ktn');
    final vault = passFile(file.path, 'old-master-password');

    try {
      await vault.newSQLFile();
      await vault.savePassword(keyTitanPass(
        title: 'Email',
        site: 'https://example.com',
        category: 'General',
        username: 'tester',
        displayPassword: 'entry-secret',
      ));

      expect(
        await vault.changeMasterPassword(
          currentPassword: 'wrong-master-password',
          newPassword: 'new-master-password',
        ),
        isFalse,
      );
      expect(
        await vault.changeMasterPassword(
          currentPassword: 'old-master-password',
          newPassword: 'new-master-password',
        ),
        isTrue,
      );
      await vault.dispose();

      final oldPasswordAttempt = passFile(file.path, 'old-master-password');
      try {
        expect(await oldPasswordAttempt.attemptDecrypt(), isFalse);
      } finally {
        await oldPasswordAttempt.dispose();
      }

      final newPasswordAttempt = passFile(file.path, 'new-master-password');
      try {
        expect(await newPasswordAttempt.attemptDecrypt(), isTrue);
        final rows = await newPasswordAttempt.getPasswordsByCategory('General');
        expect(rows, hasLength(1));
        final plainText = await keyTitanPass.hdecrypt(
          newPasswordAttempt.passwordBytes,
          rows.first['password'] as String,
        );
        expect(plainText, 'entry-secret');
      } finally {
        await newPasswordAttempt.dispose();
      }
    } finally {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });
}
