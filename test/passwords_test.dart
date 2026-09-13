import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/passwords.dart';
import 'package:keytitan/globals.dart';
import 'package:keytitan/vault_format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('attemptDecrypt rejects unsupported vault files', () async {
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
    expect(KeyTitanVaultFiles.safeFileName('bad:name.ktn'), isNull);
    expect(KeyTitanVaultFiles.safeFileName('vault.pass'), isNull);
  });

  test('derived autofill origins do not invent sibling subdomains', () {
    final derived = jsonDecode(keyTitanPass.deriveUris('example.com')) as List;

    expect(derived, contains('https://example.com'));
    expect(derived, isNot(contains('https://www.example.com')));
  });

  test('changeMasterPassword rotates and rewraps the vault key', () async {
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
      expect(await vault.attemptEncrypt(), isTrue);
      expect(
        KeyTitanVaultCodec.detectVersion(await file.readAsBytes()),
        KeyTitanVaultVersion.v4,
      );
      final beforePasswordChange = await file.readAsBytes();
      await vault.dispose();

      final unlocked = passFile(file.path, 'old-master-password');
      expect(await unlocked.attemptDecrypt(), isTrue);
      final autofillEpochBeforePasswordChange = unlocked.autofillSessionEpoch;
      final fieldBeforePasswordChange =
          (await unlocked.getPasswordsByCategory('General')).first['password'];

      expect(
        await unlocked.changeMasterPassword(
          currentPassword: 'wrong-master-password',
          newPassword: 'new-master-password',
        ),
        isFalse,
      );
      expect(
        await unlocked.changeMasterPassword(
          currentPassword: 'old-master-password',
          newPassword: 'new-master-password',
        ),
        isTrue,
      );
      expect(
        unlocked.autofillSessionEpoch,
        isNot(autofillEpochBeforePasswordChange),
        reason: 'DEK rotation must invalidate in-flight autofill authority',
      );
      final afterPasswordChange = await file.readAsBytes();
      expect(
        afterPasswordChange.sublist(20, 36),
        orderedEquals(beforePasswordChange.sublist(20, 36)),
        reason: 'the vault identity must remain stable',
      );
      expect(
        afterPasswordChange.sublist(36, 112),
        isNot(orderedEquals(beforePasswordChange.sublist(36, 112))),
        reason: 'salt, wrapping nonce, and wrapped DEK must be refreshed',
      );
      expect(
        ByteData.sublistView(afterPasswordChange).getUint64(112, Endian.big),
        2,
      );
      expect(
        (await unlocked.getPasswordsByCategory('General')).first['password'],
        isNot(fieldBeforePasswordChange),
        reason: 'password fields must be rekeyed under the replacement DEK',
      );
      await unlocked.dispose();

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
        final plainText = await newPasswordAttempt.decryptPassword(
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

  test('new vault refuses to overwrite a file that appears before save',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/vault.ktn');
    final vault = passFile(file.path, 'test-master-password');
    final sentinel = List<int>.generate(64, (index) => index);

    try {
      await vault.newSQLFile();
      await file.writeAsBytes(sentinel, flush: true);

      expect(await vault.attemptEncrypt(), isFalse);
      expect(await file.readAsBytes(), sentinel);
    } finally {
      await vault.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('routine KTN4 saves preserve the wrapped key and advance revision',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/vault.ktn');
    final vault = passFile(file.path, 'test-master-password');

    try {
      await vault.newSQLFile();
      final entry = keyTitanPass(
        title: 'Email',
        site: 'https://example.com',
        category: 'General',
        username: 'tester',
        displayPassword: 'first-secret',
      );
      await vault.savePassword(entry);
      expect(await vault.attemptEncrypt(), isTrue);
      final first = await file.readAsBytes();

      entry.displayPassword = 'second-secret';
      await vault.savePassword(entry);
      expect(await vault.attemptEncrypt(), isTrue);
      final second = await file.readAsBytes();

      expect(
        KeyTitanVaultCodec.detectVersion(first),
        KeyTitanVaultVersion.v4,
      );
      expect(first.sublist(0, 112), orderedEquals(second.sublist(0, 112)));
      expect(ByteData.sublistView(first).getUint64(112, Endian.big), 1);
      expect(ByteData.sublistView(second).getUint64(112, Endian.big), 2);
      expect(first.sublist(120), isNot(orderedEquals(second.sublist(120))));

      final rows = await vault.getPasswordsByCategory('General');
      expect(rows.first['password'], startsWith('c20p2:'));
      expect(
        await vault.decryptPassword(rows.first['password'] as String),
        'second-secret',
      );
    } finally {
      await vault.dispose();
      await dir.delete(recursive: true);
    }
  });

  test('queued mutation cannot be lost behind an in-flight vault save',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/vault.ktn');
    final vault = passFile(file.path, 'test-master-password');

    try {
      await vault.newSQLFile();
      final entry = keyTitanPass(
        title: 'Email',
        site: 'https://example.com',
        category: 'General',
        username: 'tester',
        displayPassword: 'first-secret',
      );
      await vault.savePassword(entry);

      final firstSave = vault.attemptEncrypt();
      entry.displayPassword = 'queued-secret';
      final queuedMutation = vault.savePassword(entry);
      final secondSave = vault.attemptEncrypt();

      expect(await firstSave, isTrue);
      await queuedMutation;
      expect(await secondSave, isTrue);

      final twiceSaved = await file.readAsBytes();
      expect(ByteData.sublistView(twiceSaved).getUint64(112, Endian.big), 2);

      // A clean save is a no-op, including at the byte level.
      expect(await vault.attemptEncrypt(), isTrue);
      expect(await file.readAsBytes(), orderedEquals(twiceSaved));
      await vault.dispose();

      final reopened = passFile(file.path, 'test-master-password');
      try {
        expect(await reopened.attemptDecrypt(), isTrue);
        final rows = await reopened.getPasswordsByCategory('General');
        expect(
          await reopened.decryptPassword(rows.first['password'] as String),
          'queued-secret',
        );
      } finally {
        await reopened.dispose();
      }
    } finally {
      await vault.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('KTN3 unlocks and silently migrates to KTN4 on save', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/legacy.ktn');
    await _writeLegacyKtn3Vault(file, 'legacy-master-password');
    final vault = passFile(file.path, 'legacy-master-password');

    try {
      expect(
        KeyTitanVaultCodec.detectVersion(await file.readAsBytes()),
        KeyTitanVaultVersion.v3,
      );
      expect(await vault.attemptDecrypt(), isTrue);
      final legacyRows = await vault.getPasswordsByCategory('Legacy');
      expect(legacyRows.first['password'], startsWith('c20p1:'));
      expect(
        await vault.decryptPassword(legacyRows.first['password'] as String),
        'legacy-entry-secret',
      );

      expect(await vault.attemptEncrypt(), isTrue);
      expect(
        KeyTitanVaultCodec.detectVersion(await file.readAsBytes()),
        KeyTitanVaultVersion.v4,
      );
      final migratedRows = await vault.getPasswordsByCategory('Legacy');
      expect(migratedRows.first['password'], startsWith('c20p2:'));
      expect(
        await vault.decryptPassword(migratedRows.first['password'] as String),
        'legacy-entry-secret',
      );
      await vault.dispose();

      final reopened = passFile(file.path, 'legacy-master-password');
      try {
        expect(await reopened.attemptDecrypt(), isTrue);
        final rows = await reopened.getPasswordsByCategory('Legacy');
        expect(
          await reopened.decryptPassword(rows.first['password'] as String),
          'legacy-entry-secret',
        );
      } finally {
        await reopened.dispose();
      }
    } finally {
      await vault.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('changing a KTN3 master password migrates and rekeys atomically',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/legacy.ktn');
    await _writeLegacyKtn3Vault(file, 'legacy-master-password');
    final vault = passFile(file.path, 'legacy-master-password');

    try {
      expect(await vault.attemptDecrypt(), isTrue);
      expect(
        await vault.changeMasterPassword(
          currentPassword: 'legacy-master-password',
          newPassword: 'replacement-master-password',
        ),
        isTrue,
      );
      expect(
        KeyTitanVaultCodec.detectVersion(await file.readAsBytes()),
        KeyTitanVaultVersion.v4,
      );
      await vault.dispose();

      final oldAttempt = passFile(file.path, 'legacy-master-password');
      try {
        expect(await oldAttempt.attemptDecrypt(), isFalse);
      } finally {
        await oldAttempt.dispose();
      }

      final replacementAttempt =
          passFile(file.path, 'replacement-master-password');
      try {
        expect(await replacementAttempt.attemptDecrypt(), isTrue);
        final rows = await replacementAttempt.getPasswordsByCategory('Legacy');
        expect(rows.first['password'], startsWith('c20p2:'));
        expect(
          await replacementAttempt.decryptPassword(
            rows.first['password'] as String,
          ),
          'legacy-entry-secret',
        );
      } finally {
        await replacementAttempt.dispose();
      }
    } finally {
      await vault.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('KTN4 rejects tampering in parameters, wrapped key, and payload',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_test_');
    final file = File('${dir.path}/vault.ktn');
    final vault = passFile(file.path, 'test-master-password');

    try {
      await vault.newSQLFile();
      await vault.savePassword(keyTitanPass(
        title: 'Email',
        site: 'https://example.com',
        category: 'General',
        username: 'tester',
        displayPassword: 'entry-secret',
      ));
      expect(await vault.attemptEncrypt(), isTrue);
      final valid = await file.readAsBytes();
      await vault.dispose();

      for (final offset in <int>[4, 8, 20, 36, 52, 64, 112, 120, 132]) {
        final tampered = Uint8List.fromList(valid);
        tampered[offset] ^= 0x01;
        await file.writeAsBytes(tampered, flush: true);
        final attempt = passFile(file.path, 'test-master-password');
        try {
          expect(
            await attempt.attemptDecrypt(),
            isFalse,
            reason: 'tampering at offset $offset must be authenticated',
          );
        } finally {
          await attempt.dispose();
        }
      }
    } finally {
      await vault.dispose();
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });
}

Future<void> _writeLegacyKtn3Vault(File vaultFile, String password) async {
  final sqliteFile = File('${vaultFile.path}.sqlite');
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final fieldCipher = await keyTitanPass.hencrypt(
    passwordBytes,
    'legacy-entry-secret',
  );

  final database = sqlite.sqlite3.open(sqliteFile.path);
  try {
    database.execute(
      'CREATE TABLE category(id INTEGER PRIMARY KEY, category TEXT UNIQUE);',
    );
    database.execute(
      'CREATE TABLE password('
      'id INTEGER PRIMARY KEY, title TEXT, site TEXT, category_id INTEGER, '
      'username TEXT, password TEXT, uris TEXT, '
      'FOREIGN KEY(category_id) REFERENCES category(id));',
    );
    database.execute(
      'INSERT INTO category(id, category) VALUES (?, ?)',
      [1, 'Legacy'],
    );
    database.execute(
      'INSERT INTO password('
      'id, title, site, category_id, username, password, uris'
      ') VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        1,
        'Legacy Email',
        'https://example.com',
        1,
        'legacy-user',
        fieldCipher,
        '[]',
      ],
    );
  } finally {
    database.close();
  }

  final sqliteBytes = await sqliteFile.readAsBytes();
  final salt = Uint8List.fromList(List<int>.generate(16, (index) => index + 1));
  final nonce =
      Uint8List.fromList(List<int>.generate(12, (index) => index + 17));
  final argon2 = crypto.Argon2id(
    memory: KeyTitanVaultCodec.argonMemoryKiB,
    parallelism: KeyTitanVaultCodec.argonParallelism,
    iterations: KeyTitanVaultCodec.argonIterations,
    hashLength: KeyTitanVaultCodec.keyLength,
  );
  final secretKey = await argon2.deriveKeyFromPassword(
    password: password,
    nonce: salt,
  );
  final key = Uint8List.fromList(await secretKey.extractBytes());
  try {
    final box = await crypto.Chacha20.poly1305Aead().encrypt(
      sqliteBytes,
      secretKey: crypto.SecretKey(key),
      nonce: nonce,
    );
    final payload = box.cipherText + box.mac.bytes;
    final output = Uint8List(32 + payload.length)
      ..setRange(0, 4, KeyTitanVaultCodec.v3Magic)
      ..setRange(4, 16, nonce)
      ..setRange(16, 32, salt)
      ..setRange(32, 32 + payload.length, payload);
    await vaultFile.writeAsBytes(output, flush: true);
    output.fillRange(0, output.length, 0);
  } finally {
    passwordBytes.fillRange(0, passwordBytes.length, 0);
    key.fillRange(0, key.length, 0);
    sqliteBytes.fillRange(0, sqliteBytes.length, 0);
    if (await sqliteFile.exists()) await sqliteFile.delete();
  }
}
