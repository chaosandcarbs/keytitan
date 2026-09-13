// ignore_for_file: camel_case_types
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:typed_data/typed_buffers.dart';
import 'globals.dart';
import 'vault_format.dart';

const String _memorySqlitePath = '/keytitan.sqlite';

Uint8List _secureRandomBytes(int length) {
  final rand = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => rand.nextInt(256)));
}

class passFile {
  final String fileName; // full path to the .ktn file
  Uint8List? _passwordBytes; // Retained only until KTN4 unlock/wrapping.
  Uint8List? _vaultKeyBytes; // Random KTN4 DEK, zeroed when the vault locks.
  Ktn4KeyEnvelope? _keyEnvelope;
  int _revision = 0;
  bool _loadedFromV3 = false;
  bool _dirty = false;
  String _autofillSessionEpoch = _newAutofillSessionEpoch();

  Database? _db;
  bool _preventInitialOverwrite = false;
  Future<void> _operationTail = Future<void>.value();
  String? _diskFingerprint;
  String? get diskFingerprint => _diskFingerprint;

  Future<bool> get isCurrentOnDisk async {
    final f = File(fileName);
    return await f.exists() &&
        dart_crypto.sha256
                .convert(await f.readAsBytes())
                .toString()
                .toUpperCase() ==
            _diskFingerprint;
  }

  passFile(this.fileName, String password)
      : _passwordBytes = Uint8List.fromList(utf8.encode(password));

  bool get needsSave =>
      _dirty || _loadedFromV3 || _vaultKeyBytes == null || _keyEnvelope == null;

  String? get autofillVaultId {
    final vaultId = _keyEnvelope?.vaultId;
    if (vaultId == null) return null;
    return base64Url.encode(vaultId).replaceAll('=', '');
  }

  String get autofillSessionEpoch => _autofillSessionEpoch;

  static String _newAutofillSessionEpoch() =>
      base64Url.encode(_secureRandomBytes(18)).replaceAll('=', '');

  void _rotateAutofillSessionEpoch() {
    _autofillSessionEpoch = _newAutofillSessionEpoch();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    await _operationTail;
    await _closeDb();
    _clearMasterPassword();
    final vaultKey = _vaultKeyBytes;
    vaultKey?.fillRange(0, vaultKey.length, 0);
    _vaultKeyBytes = null;
    _keyEnvelope = null;
  }

  Future<void> _closeDb() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }

  // Opens a blank in-memory database. Call this when creating a new file.
  Future<void> newSQLFile() async {
    await _initDatabase();
    _vaultKeyBytes = _secureRandomBytes(KeyTitanVaultCodec.keyLength);
    _loadedFromV3 = false;
    _revision = 0;
    _dirty = true;
    _preventInitialOverwrite = true;
  }

  Future<Database> _initDatabase() async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
    );
    return _db!;
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS category('
      'id INTEGER PRIMARY KEY, category TEXT UNIQUE);',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS password('
      'id INTEGER PRIMARY KEY, '
      'title TEXT, site TEXT, category_id INTEGER, username TEXT, '
      'password TEXT, uris TEXT, '
      'FOREIGN KEY(category_id) REFERENCES category(id));',
    );
  }

  // ---------------------------------------------------------------------------
  // Encrypt / Decrypt
  // ---------------------------------------------------------------------------

  // KTN3 remains readable for migration. KTN4 unwraps its random vault key with
  // the supplied master password, then discards the master password bytes.
  Future<bool> attemptDecrypt() => _runSerialized(_attemptDecryptOnce);

  Future<bool> _attemptDecryptOnce() async {
    try {
      final f = File(fileName);
      if (!await f.exists()) return false;
      final encData = await f.readAsBytes();
      _diskFingerprint =
          dart_crypto.sha256.convert(encData).toString().toUpperCase();
      final password = _passwordBytes;
      if (password == null) return false;

      switch (KeyTitanVaultCodec.detectVersion(encData)) {
        case KeyTitanVaultVersion.v4:
          final decoded = await KeyTitanVaultCodec.decryptV4(encData, password);
          if (decoded == null) return false;
          var accepted = false;
          try {
            await _loadDbFromBytes(decoded.sqliteBytes);
            _vaultKeyBytes = decoded.vaultKey;
            _keyEnvelope = decoded.envelope;
            _revision = decoded.revision;
            _loadedFromV3 = false;
            _dirty = false;
            _clearMasterPassword();
            accepted = true;
            return true;
          } finally {
            if (!accepted) {
              decoded.vaultKey.fillRange(0, decoded.vaultKey.length, 0);
            }
          }
        case KeyTitanVaultVersion.v3:
          final decrypted =
              await KeyTitanVaultCodec.decryptV3(encData, password);
          if (decrypted == null) return false;
          await _loadDbFromBytes(decrypted);
          _vaultKeyBytes = null;
          _keyEnvelope = null;
          _revision = 0;
          _loadedFromV3 = true;
          _dirty = false;
          return true;
        case KeyTitanVaultVersion.unknown:
          return false;
      }
    } catch (e) {
      debugPrint('Decryption error: $e');
      return false;
    }
  }

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Uint8List _requireMasterPassword() {
    final password = _passwordBytes;
    if (password == null || password.isEmpty) {
      throw StateError('The master password is not available.');
    }
    return password;
  }

  void _clearMasterPassword() {
    final password = _passwordBytes;
    password?.fillRange(0, password.length, 0);
    _passwordBytes = null;
  }

  // Every successful save writes KTN4. A loaded KTN3 vault is migrated in
  // memory first, and rolled back if wrapping, encryption, or persistence fails.
  Future<bool> attemptEncrypt() => _runSerialized(_attemptEncryptOnce);

  Future<bool> _attemptEncryptOnce() async {
    if (_db == null || !_db!.isOpen) return false;
    if (!needsSave) return true;

    Uint8List? migrationKey;
    var migrationApplied = false;
    var migrationRollbackSucceeded = true;
    var migrationUpdates = const <_PasswordCipherUpdate>[];
    Uint8List? rawBytes;
    try {
      var vaultKey = _vaultKeyBytes;
      var envelope = _keyEnvelope;

      if (vaultKey == null) {
        if (!_loadedFromV3) {
          throw StateError('An initialized KTN4 vault has no vault key.');
        }
        migrationKey = _secureRandomBytes(KeyTitanVaultCodec.keyLength);
        vaultKey = migrationKey;
        _vaultKeyBytes = vaultKey;
      }

      if (_loadedFromV3) {
        final masterPassword = _requireMasterPassword();
        migrationUpdates = await _buildV3FieldMigrationUpdates(
          masterPassword,
          vaultKey,
        );
        await _applyPasswordCipherUpdates(
          _db!,
          migrationUpdates,
          useNewCipher: true,
        );
        migrationApplied = true;
      }

      envelope ??= await KeyTitanVaultCodec.createEnvelope(
        _requireMasterPassword(),
        vaultKey,
      );

      rawBytes = await _exportDbToBytes();
      final encoded = await KeyTitanVaultCodec.encryptV4(
        rawBytes,
        vaultKey,
        envelope,
        _revision,
      );
      try {
        await _writeVaultBytesAtomic(encoded.bytes);
        _diskFingerprint =
            dart_crypto.sha256.convert(encoded.bytes).toString().toUpperCase();
      } finally {
        encoded.bytes.fillRange(0, encoded.bytes.length, 0);
      }

      _vaultKeyBytes = vaultKey;
      _keyEnvelope = envelope;
      _revision = encoded.revision;
      _loadedFromV3 = false;
      _dirty = false;
      _clearMasterPassword();
      migrationKey = null; // Ownership transferred to _vaultKeyBytes.
      return true;
    } catch (e) {
      if (migrationApplied) {
        try {
          await _applyPasswordCipherUpdates(
            _db!,
            migrationUpdates,
            useNewCipher: false,
          );
        } catch (rollbackError) {
          migrationRollbackSucceeded = false;
          debugPrint('KTN3 migration rollback error: $rollbackError');
        }
      }
      if (migrationKey != null) {
        if (migrationRollbackSucceeded) {
          if (identical(_vaultKeyBytes, migrationKey)) _vaultKeyBytes = null;
          migrationKey.fillRange(0, migrationKey.length, 0);
        } else {
          // If an in-memory rollback itself fails, retain the recovery key.
          // A later save can validate/finish any c20p1 -> c20p2 conversion
          // instead of leaving converted fields with no usable key.
          _vaultKeyBytes = migrationKey;
          _dirty = true;
          migrationKey = null;
        }
      }
      debugPrint('Encryption error: $e');
      return false;
    } finally {
      rawBytes?.fillRange(0, rawBytes.length, 0);
    }
  }

  Future<void> _writeVaultBytesAtomic(Uint8List bytes) async {
    if (Platform.isAndroid) {
      // Both Flutter engines use one native compare-and-swap commit queue.
      await const MethodChannel('app.keytitan/vault_commit').invokeMethod<void>(
        'commit',
        {'path': fileName, 'expected': _diskFingerprint, 'bytes': bytes},
      );
      _diskFingerprint =
          dart_crypto.sha256.convert(bytes).toString().toUpperCase();
      _preventInitialOverwrite = false;
      return;
    }
    final target = File(fileName);
    final dir = target.parent;
    await dir.create(recursive: true);

    // A new vault is edited in memory before its first save. Claim its path
    // exclusively at the actual write boundary, closing the gap between the
    // UI's name check and this first persistence operation.
    if (_preventInitialOverwrite) {
      var created = false;
      try {
        await target.create(exclusive: true);
        created = true;
        final raf = await target.open(mode: FileMode.writeOnly);
        try {
          await raf.writeFrom(bytes);
          await raf.flush();
        } finally {
          await raf.close();
        }
        _preventInitialOverwrite = false;
        return;
      } catch (_) {
        if (created && await target.exists()) {
          try {
            await target.delete();
          } catch (_) {}
        }
        rethrow;
      }
    }

    final baseName = p.basename(fileName);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final temp = File(p.join(dir.path, '.$baseName.$stamp.tmp'));
    final backup = File(p.join(dir.path, '.$baseName.$stamp.bak'));

    try {
      final raf = await temp.open(mode: FileMode.writeOnly);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }

      final targetExists = await target.exists();
      // On POSIX filesystems, rename over an existing file is atomic. Keep the
      // previous vault continuously present until the flushed replacement is
      // committed under its final name. Windows does not permit that rename,
      // so it uses the recoverable backup/replace sequence below.
      if (targetExists && !Platform.isWindows) {
        await temp.rename(target.path);
        return;
      }

      if (targetExists) {
        await target.rename(backup.path);
      }

      try {
        await temp.rename(target.path);
      } catch (_) {
        if (targetExists && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }

      if (await backup.exists()) {
        try {
          await backup.delete();
        } catch (e) {
          debugPrint('Could not remove vault save backup: $e');
        }
      }
    } catch (_) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // In-memory DB serialisation
  // ---------------------------------------------------------------------------

  Future<void> _loadDbFromBytes(Uint8List sqliteBytes) async {
    try {
      await _withInMemorySqliteBytes(
        sqliteBytes,
        readOnly: true,
        action: (srcDb) async {
          final categories = srcDb.select(
            'SELECT id, category FROM category ORDER BY id ASC',
          );
          final passwords = srcDb.select(
            'SELECT id, title, site, category_id, username, password, '
            'uris '
            'FROM password ORDER BY id ASC',
          );

          await _closeDb();
          _db = await databaseFactoryFfi.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
          );

          await _db!.transaction((txn) async {
            for (final row in categories) {
              await txn.insert(
                  'category',
                  {
                    'id': row['id'],
                    'category': row['category'],
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace);
            }
            for (final row in passwords) {
              await txn.insert(
                  'password',
                  {
                    'id': row['id'],
                    'title': row['title'],
                    'site': row['site'],
                    'category_id': row['category_id'],
                    'username': row['username'],
                    'password': row['password'],
                    'uris': row['uris'],
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace);
            }
          });
        },
      );
    } finally {
      sqliteBytes.fillRange(0, sqliteBytes.length, 0);
    }
  }

  Future<Uint8List> _exportDbToBytes() async {
    return _withNewInMemorySqlite((dstDb, vfs) async {
      _createSqliteSchema(dstDb);

      final categories = await _db!.query('category');
      final passwords = await _db!.query('password');

      dstDb.execute('BEGIN IMMEDIATE');
      try {
        final catStmt = dstDb.prepare(
          'INSERT OR REPLACE INTO category(id, category) VALUES (?, ?)',
        );
        final passStmt = dstDb.prepare(
          'INSERT OR REPLACE INTO password('
          'id, title, site, category_id, username, password, uris'
          ') VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        try {
          for (final row in categories) {
            catStmt.execute([row['id'], row['category']]);
          }
          for (final row in passwords) {
            passStmt.execute([
              row['id'],
              row['title'],
              row['site'],
              row['category_id'],
              row['username'],
              row['password'],
              row['uris'],
            ]);
          }
        } finally {
          catStmt.close();
          passStmt.close();
        }
        dstDb.execute('COMMIT');
      } catch (_) {
        dstDb.execute('ROLLBACK');
        rethrow;
      }

      return _readVfsDatabaseBytes(vfs);
    });
  }

  Future<T> _withInMemorySqliteBytes<T>(
    Uint8List sqliteBytes, {
    required bool readOnly,
    required Future<T> Function(sqlite.Database db) action,
  }) async {
    final buffer = Uint8Buffer()..addAll(sqliteBytes);
    return _withNewInMemorySqlite((db, _) => action(db),
        initialBuffer: buffer, readOnly: readOnly);
  }

  Future<T> _withNewInMemorySqlite<T>(
    Future<T> Function(sqlite.Database db, sqlite.InMemoryFileSystem vfs)
        action, {
    Uint8Buffer? initialBuffer,
    bool readOnly = false,
  }) async {
    final vfs = sqlite.InMemoryFileSystem(
      name: 'ktn-memory-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (initialBuffer != null) {
      vfs.fileData[_memorySqlitePath] = initialBuffer;
    }

    sqlite.sqlite3.registerVirtualFileSystem(vfs);
    final db = sqlite.sqlite3.open(
      _memorySqlitePath,
      vfs: vfs.name,
      mode:
          readOnly ? sqlite.OpenMode.readOnly : sqlite.OpenMode.readWriteCreate,
    );

    try {
      return await action(db, vfs);
    } finally {
      db.close();
      for (final buffer in vfs.fileData.values) {
        buffer?.fillRange(0, buffer.length, 0);
      }
      sqlite.sqlite3.unregisterVirtualFileSystem(vfs);
    }
  }

  Uint8List _readVfsDatabaseBytes(sqlite.InMemoryFileSystem vfs) {
    Uint8Buffer? buffer = vfs.fileData[_memorySqlitePath];
    if (buffer == null) {
      for (final entry in vfs.fileData.entries) {
        final value = entry.value;
        if (entry.key.endsWith('keytitan.sqlite') && value != null) {
          buffer = value;
          break;
        }
      }
    }
    if (buffer == null) {
      throw StateError('In-memory SQLite export did not produce bytes.');
    }
    return Uint8List.fromList(buffer);
  }

  void _createSqliteSchema(sqlite.Database db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS category('
      'id INTEGER PRIMARY KEY, category TEXT UNIQUE);',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS password('
      'id INTEGER PRIMARY KEY, '
      'title TEXT, site TEXT, category_id INTEGER, username TEXT, '
      'password TEXT, uris TEXT, '
      'FOREIGN KEY(category_id) REFERENCES category(id));',
    );
  }

  // ---------------------------------------------------------------------------
  // Database operations
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getCategories() async {
    final db = await _initDatabase();
    return db.query('category', orderBy: 'category ASC');
  }

  Future<List<Map<String, dynamic>>> getPasswordsByCategory(
      dynamic category) async {
    final db = await _initDatabase();
    final col = (category is String) ? 'B.category' : 'B.id';
    return db.rawQuery('''
      SELECT A.id, A.title, COALESCE(A.site, '') AS site,
             A.username, A.password, COALESCE(A.uris, '') AS uris,
             A.category_id, B.category
      FROM password A
      JOIN category B ON A.category_id = B.id
      WHERE $col = ?
    ''', [category]);
  }

  Future<Map<String, dynamic>?> getPasswordById(int id) async {
    final db = await _initDatabase();
    final rows = await db.rawQuery('''
      SELECT A.id, A.title, COALESCE(A.site, '') AS site,
             A.username, A.password, COALESCE(A.uris, '') AS uris,
             A.category_id, B.category
      FROM password A
      JOIN category B ON A.category_id = B.id
      WHERE A.id = ?
      LIMIT 1
    ''', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> savePassword(keyTitanPass pass) =>
      _runSerialized(() => _savePasswordOnce(pass));

  Future<int> _savePasswordOnce(keyTitanPass pass) async {
    final db = await _initDatabase();
    int catId = await getCategoryID(pass.category);
    if (catId == -1) catId = await insertCategory(pass.category);

    final vaultKey = _vaultKeyBytes;
    final encryptedField = await keyTitanPass.hencrypt(
      vaultKey ?? _requireMasterPassword(),
      pass.displayPassword,
      useVaultKey: vaultKey != null,
    );

    final data = {
      'title': pass.title,
      'site': pass.site,
      'category_id': catId,
      'username': pass.username,
      'password': encryptedField,
      'uris': pass.normalizedUris,
    };

    if (pass.id == -1) {
      pass.id = await db.insert('password', data);
      _dirty = true;
      return pass.id;
    } else {
      await db.update('password', data, where: 'id = ?', whereArgs: [pass.id]);
      await _pruneEmptyCategories(db);
      _dirty = true;
      return pass.id;
    }
  }

  Future<String> decryptPassword(String cipherText) async {
    if (cipherText.isEmpty) return '';

    if (keyTitanPass.isVaultKeyCipher(cipherText)) {
      final vaultKey = _vaultKeyBytes;
      if (vaultKey == null) return keyTitanPass.decryptionError;
      return keyTitanPass.hdecrypt(vaultKey, cipherText);
    }
    if (keyTitanPass.isLegacyCipher(cipherText)) {
      final masterPassword = _passwordBytes;
      if (masterPassword == null) return keyTitanPass.decryptionError;
      return keyTitanPass.hdecrypt(masterPassword, cipherText);
    }
    return keyTitanPass.decryptionError;
  }

  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _runSerialized(
        () => _changeMasterPasswordOnce(
          currentPassword: currentPassword,
          newPassword: newPassword,
        ),
      );

  Future<bool> _changeMasterPasswordOnce({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (currentPassword.isEmpty || newPassword.isEmpty) return false;

    await _initDatabase();
    final currentBytes = Uint8List.fromList(utf8.encode(currentPassword));
    final newBytes = Uint8List.fromList(utf8.encode(newPassword));
    final oldVaultKey = _vaultKeyBytes;
    final oldEnvelope = _keyEnvelope;
    final oldDirty = _dirty;
    Uint8List? replacementKey;
    Ktn4KeyEnvelope? replacementEnvelope;
    var rekeyApplied = false;
    var rekeyUpdates = const <_PasswordCipherUpdate>[];

    Future<void> restoreAfterFailure() async {
      _keyEnvelope = oldEnvelope;
      var rollbackSucceeded = true;
      if (rekeyApplied) {
        try {
          await _applyPasswordCipherUpdates(
            _db!,
            rekeyUpdates,
            useNewCipher: false,
          );
        } catch (rollbackError) {
          rollbackSucceeded = false;
          debugPrint('Password change rollback error: $rollbackError');
        }
      }

      if (rollbackSucceeded) {
        _vaultKeyBytes = oldVaultKey;
        _dirty = oldDirty;
        return;
      }

      // Preserve the replacement key and its envelope if an in-memory rekey
      // could not be rolled back. A later save can persist this internally
      // consistent state instead of leaving rekeyed fields unreadable.
      _vaultKeyBytes = replacementKey;
      _keyEnvelope = replacementEnvelope;
      _dirty = true;
      _rotateAutofillSessionEpoch();
      replacementKey = null;
    }

    try {
      final bool passwordMatches;
      if (oldVaultKey != null && oldEnvelope != null) {
        passwordMatches = await KeyTitanVaultCodec.passwordUnlocksEnvelope(
          currentBytes,
          oldVaultKey,
          oldEnvelope,
        );
      } else {
        final storedPassword = _passwordBytes;
        passwordMatches = storedPassword != null &&
            _constantTimeEquals(storedPassword, currentBytes);
      }
      if (!passwordMatches) return false;

      // Invalidate every in-flight autofill capability before the DEK starts
      // transitioning, including paths that later roll back.
      _rotateAutofillSessionEpoch();
      replacementKey = _secureRandomBytes(KeyTitanVaultCodec.keyLength);
      replacementEnvelope = await KeyTitanVaultCodec.createEnvelope(
        newBytes,
        replacementKey!,
        vaultId: oldEnvelope?.vaultId,
      );

      rekeyUpdates = await _buildPasswordChangeFieldUpdates(
        oldVaultKey: oldVaultKey,
        legacyMasterPassword: _passwordBytes,
        replacementKey: replacementKey!,
      );
      await _applyPasswordCipherUpdates(
        _db!,
        rekeyUpdates,
        useNewCipher: true,
      );
      rekeyApplied = true;

      _vaultKeyBytes = replacementKey;
      _keyEnvelope = replacementEnvelope;
      _dirty = true;

      if (await _attemptEncryptOnce()) {
        oldVaultKey?.fillRange(0, oldVaultKey.length, 0);
        _rotateAutofillSessionEpoch();
        replacementKey = null; // Ownership transferred to _vaultKeyBytes.
        return true;
      }

      await restoreAfterFailure();
      return false;
    } catch (e) {
      debugPrint('Password change error: $e');
      await restoreAfterFailure();
      return false;
    } finally {
      currentBytes.fillRange(0, currentBytes.length, 0);
      newBytes.fillRange(0, newBytes.length, 0);
      final keyToWipe = replacementKey;
      keyToWipe?.fillRange(0, keyToWipe.length, 0);
    }
  }

  Future<List<_PasswordCipherUpdate>> _buildPasswordChangeFieldUpdates({
    required Uint8List? oldVaultKey,
    required Uint8List? legacyMasterPassword,
    required Uint8List replacementKey,
  }) async {
    final rows = await _db!.query('password', columns: ['id', 'password']);
    final updates = <_PasswordCipherUpdate>[];
    for (final row in rows) {
      final oldCipher = row['password']?.toString() ?? '';
      if (oldCipher.isEmpty) continue;

      final Uint8List decryptKey;
      if (keyTitanPass.isVaultKeyCipher(oldCipher)) {
        if (oldVaultKey == null) {
          throw StateError('A c20p2 field has no current vault key.');
        }
        decryptKey = oldVaultKey;
      } else if (keyTitanPass.isLegacyCipher(oldCipher)) {
        if (legacyMasterPassword == null) {
          throw StateError('A c20p1 field has no legacy master password.');
        }
        decryptKey = legacyMasterPassword;
      } else {
        throw StateError('Vault contains an unsupported field cipher.');
      }

      final plainText = await keyTitanPass.hdecrypt(decryptKey, oldCipher);
      if (plainText == keyTitanPass.decryptionError) {
        throw StateError('Could not decrypt a password field while rekeying.');
      }
      final newCipher = await keyTitanPass.hencrypt(
        replacementKey,
        plainText,
        useVaultKey: true,
      );
      updates.add(
        _PasswordCipherUpdate(row['id'] as int, oldCipher, newCipher),
      );
    }
    return updates;
  }

  Future<List<_PasswordCipherUpdate>> _buildV3FieldMigrationUpdates(
    Uint8List masterPassword,
    Uint8List vaultKey,
  ) async {
    final rows = await _db!.query('password', columns: ['id', 'password']);
    final updates = <_PasswordCipherUpdate>[];
    for (final row in rows) {
      final oldCipher = row['password']?.toString() ?? '';
      if (oldCipher.isEmpty) continue;
      if (keyTitanPass.isVaultKeyCipher(oldCipher)) {
        final plainText = await keyTitanPass.hdecrypt(vaultKey, oldCipher);
        if (plainText == keyTitanPass.decryptionError) {
          throw StateError('Could not validate a migrated password field.');
        }
        continue;
      }
      if (!keyTitanPass.isLegacyCipher(oldCipher)) {
        throw StateError('KTN3 vault contains an unsupported field cipher.');
      }
      final plainText = await keyTitanPass.hdecrypt(masterPassword, oldCipher);
      if (plainText == keyTitanPass.decryptionError) {
        throw StateError('Could not decrypt a KTN3 password field.');
      }
      final newCipher = await keyTitanPass.hencrypt(
        vaultKey,
        plainText,
        useVaultKey: true,
      );
      updates.add(
        _PasswordCipherUpdate(row['id'] as int, oldCipher, newCipher),
      );
    }
    return updates;
  }

  Future<void> _applyPasswordCipherUpdates(
    Database db,
    List<_PasswordCipherUpdate> updates, {
    required bool useNewCipher,
  }) async {
    if (updates.isEmpty) return;
    await db.transaction((txn) async {
      for (final update in updates) {
        await txn.update(
          'password',
          {'password': useNewCipher ? update.newCipher : update.oldCipher},
          where: 'id = ?',
          whereArgs: [update.id],
        );
      }
    });
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    var diff = left.length ^ right.length;
    final maxLength = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < maxLength; i++) {
      final leftByte = i < left.length ? left[i] : 0;
      final rightByte = i < right.length ? right[i] : 0;
      diff |= leftByte ^ rightByte;
    }
    return diff == 0;
  }

  Future<int> getCategoryID(String category) async {
    final db = await _initDatabase();
    final res = await db
        .query('category', where: 'category = ?', whereArgs: [category]);
    return res.isNotEmpty ? res.first['id'] as int : -1;
  }

  Future<int> insertCategory(String category) async {
    final db = await _initDatabase();
    final id = await db.insert('category', {'category': category},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _dirty = true;
    return id;
  }

  Future<void> deletePassword(int id) =>
      _runSerialized(() => _deletePasswordOnce(id));

  Future<void> _deletePasswordOnce(int id) async {
    final db = await _initDatabase();
    await db.delete('password', where: 'id = ?', whereArgs: [id]);
    await _pruneEmptyCategories(db);
    _dirty = true;
  }

  Future<void> _pruneEmptyCategories(Database db) async {
    await db.transaction((txn) async {
      final orphans = await txn.rawQuery(
        'SELECT A.id FROM category A '
        'LEFT JOIN password B ON B.category_id = A.id WHERE B.id IS NULL',
      );
      for (final row in orphans) {
        await txn.delete('category', where: 'id = ?', whereArgs: [row['id']]);
      }
    });
  }
}

class _PasswordCipherUpdate {
  final int id;
  final String oldCipher;
  final String newCipher;

  const _PasswordCipherUpdate(this.id, this.oldCipher, this.newCipher);
}

// ---------------------------------------------------------------------------
// keyTitanPass - a single password entry
// ---------------------------------------------------------------------------

class keyTitanPass {
  int id;
  String title;
  String site;
  String category;
  String username;
  String displayPassword;
  String uris;

  keyTitanPass({
    this.id = -1,
    required this.title,
    required this.site,
    required this.category,
    required this.username,
    this.displayPassword = '',
    this.uris = '',
  });

  String get normalizedUris {
    if (uris.trim().isNotEmpty) return normalizeUriOverrides(uris);
    return deriveUris(site);
  }

  static String normalizeUriOverrides(String rawUris) {
    final trimmed = rawUris.trim();
    if (trimmed.isEmpty) return '[]';

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return jsonEncode(_cleanUriValues(
          decoded.map((value) => value.toString()),
        ));
      }
    } catch (_) {}

    return jsonEncode(_cleanUriValues(
      trimmed.split(RegExp(r'[\r\n,]+')),
    ));
  }

  static String displayUris(String storedUris) {
    final trimmed = storedUris.trim();
    if (trimmed.isEmpty) return '';

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return _cleanUriValues(decoded.map((value) => value.toString()))
            .join('\n');
      }
    } catch (_) {}

    return trimmed;
  }

  static List<String> _cleanUriValues(Iterable<String> values) {
    final cleaned = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || cleaned.contains(trimmed)) continue;
      cleaned.add(trimmed);
    }
    return cleaned;
  }

  // ---------------------------------------------------------------------------
  // Field-level ChaCha20-Poly1305 encryption
  //
  // Individual password fields are encrypted inside the SQLite DB as a second
  // layer. KTN3 fields use c20p1 with the master password as their seed. KTN4
  // fields use c20p2 with the random vault key, allowing master-password bytes
  // to be discarded immediately after unlock.
  // ---------------------------------------------------------------------------

  static const String _legacyFieldCipherPrefix = 'c20p1';
  static const String _vaultKeyFieldCipherPrefix = 'c20p2';
  static const String decryptionError = '[Decryption Error]';
  static final _fieldCipher = crypto.Chacha20.poly1305Aead();

  static bool isLegacyCipher(String cipherText) =>
      cipherText.startsWith('$_legacyFieldCipherPrefix:');

  static bool isVaultKeyCipher(String cipherText) =>
      cipherText.startsWith('$_vaultKeyFieldCipherPrefix:');

  static Uint8List _deriveFieldKey(
    Uint8List seedBytes, {
    required bool useVaultKey,
  }) {
    final labelBytes = utf8.encode(
      useVaultKey
          ? 'KeyTitan field encryption v2'
          : 'KeyTitan field encryption v1',
    );
    // c20p1 must retain its historical derivation exactly. c20p2 starts from
    // a uniformly random 256-bit DEK, so HMAC-SHA-256 is a conventional,
    // domain-separated PRF for deriving its independent field-encryption key.
    final digest = useVaultKey
        ? dart_crypto.Hmac(dart_crypto.sha256, seedBytes).convert(labelBytes)
        : dart_crypto.sha256.convert([...labelBytes, ...seedBytes]);
    return Uint8List.fromList(digest.bytes);
  }

  static Future<String> hencrypt(
    Uint8List seedBytes,
    String plainText, {
    bool useVaultKey = false,
  }) async {
    if (plainText.isEmpty) return '';

    final nonce = _secureRandomBytes(12);
    final keyBytes = _deriveFieldKey(
      seedBytes,
      useVaultKey: useVaultKey,
    );
    try {
      final secretKey = await _fieldCipher.newSecretKeyFromBytes(keyBytes);
      final box = await _fieldCipher.encrypt(
        utf8.encode(plainText),
        secretKey: secretKey,
        nonce: nonce,
      );
      final payload = Uint8List.fromList(box.cipherText + box.mac.bytes);
      final prefix =
          useVaultKey ? _vaultKeyFieldCipherPrefix : _legacyFieldCipherPrefix;
      return '$prefix:${base64.encode(nonce)}:${base64.encode(payload)}';
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }

  static Future<String> hdecrypt(Uint8List seedBytes, String cipherText) async {
    if (cipherText.isEmpty) return '';

    if (!isLegacyCipher(cipherText) && !isVaultKeyCipher(cipherText)) {
      return decryptionError;
    }

    return _hdecryptChaCha20(seedBytes, cipherText);
  }

  static Future<String> _hdecryptChaCha20(
    Uint8List seedBytes,
    String cipherText,
  ) async {
    try {
      final parts = cipherText.split(':');
      if (parts.length != 3) return decryptionError;
      final nonce = base64.decode(parts[1]);
      final payload = base64.decode(parts[2]);
      if (nonce.length != 12 || payload.length < 16) {
        return decryptionError;
      }

      final keyBytes = _deriveFieldKey(
        seedBytes,
        useVaultKey: isVaultKeyCipher(cipherText),
      );
      try {
        final secretKey = await _fieldCipher.newSecretKeyFromBytes(keyBytes);
        final box = crypto.SecretBox(
          payload.sublist(0, payload.length - 16),
          nonce: nonce,
          mac: crypto.Mac(payload.sublist(payload.length - 16)),
        );
        final decrypted = await _fieldCipher.decrypt(box, secretKey: secretKey);
        return utf8.decode(decrypted);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }
    } catch (_) {
      return decryptionError;
    }
  }

  static String genPassword(Complexity complexity, int length) {
    final alphabet = complexity.getAlphabet();
    final rand = Random.secure();
    return List.generate(length, (_) => alphabet[rand.nextInt(alphabet.length)])
        .join();
  }

  static String deriveUris(String site) {
    final raw = site.trim();
    if (raw.isEmpty) return '[]';

    // Explicit origins retain their scheme and port. Never invent aliases.
    if (raw.contains('://')) return jsonEncode([raw]);
    final values = <String>{raw};
    final host = raw.split('/').first.toLowerCase();

    if (host.isNotEmpty) {
      values.add(host);
      if (host.contains('.')) {
        values.add('https://$host');
      }
    }

    return jsonEncode(values.toList());
  }
}
