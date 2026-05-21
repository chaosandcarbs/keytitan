// ignore_for_file: camel_case_types
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:typed_data/typed_buffers.dart';
import 'globals.dart';
import 'native_core.dart';

// ---------------------------------------------------------------------------
// .ktn file format
// ---------------------------------------------------------------------------
// v3: [4-byte magic "KTN3"] [12-byte ChaCha20 nonce]
//               [16-byte Argon2id salt] [ciphertext+16-byte Poly1305 MAC]
//   Key: Argon2id(memory=64MB, parallelism=2, iterations=3) -> 32 bytes.
//   A fresh random nonce and salt are written on every save.
// ---------------------------------------------------------------------------

// 4-byte magic that identifies a v3 file.
const List<int> _kV3Magic = [0x4B, 0x54, 0x4E, 0x33]; // "KTN3"
const String _memorySqlitePath = '/keytitan.sqlite';

Uint8List _secureRandomBytes(int length) {
  final rand = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => rand.nextInt(256)));
}

class passFile {
  final String fileName; // full path to the .ktn file
  Uint8List _passwordBytes; // zeroed on dispose or password change

  Database? _db;

  passFile(this.fileName, String password)
      : _passwordBytes = Uint8List.fromList(utf8.encode(password));

  // Expose key material only for field-level decryption. Do not hold the
  // returned reference longer than the immediate call.
  Uint8List get passwordBytes => _passwordBytes;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    await _closeDb();
    _passwordBytes.fillRange(0, _passwordBytes.length, 0);
  }

  Future<void> _closeDb() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }

  // Opens a blank in-memory database. Call this when creating a new file.
  Future<void> newSQLFile() async {
    try {
      await _initDatabase();
    } catch (e) {
      debugPrint('Error initialising in-memory DB: $e');
    }
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
  // Key derivation
  // ---------------------------------------------------------------------------

  // Argon2id with OWASP-recommended interactive-login parameters.
  // Returns 32 bytes; caller must zero after use.
  Future<Uint8List> _deriveKeyArgon2id(
      Uint8List passBytes, Uint8List salt) async {
    final argon2 = crypto.Argon2id(
      memory: 65536,
      parallelism: 2,
      iterations: 3,
      hashLength: 32,
    );
    final secretKey = await argon2.deriveKeyFromPassword(
      password: utf8.decode(passBytes, allowMalformed: true),
      nonce: salt,
    );
    return Uint8List.fromList(await secretKey.extractBytes());
  }

  // ---------------------------------------------------------------------------
  // Encrypt / Decrypt
  // ---------------------------------------------------------------------------

  // Reads a v3 .ktn file, decrypts it, and loads the result into an in-memory
  // SQLite database.
  Future<bool> attemptDecrypt() async {
    try {
      final f = File(fileName);
      if (!await f.exists()) return false;
      final encData = await f.readAsBytes();

      // Layout: [4 magic][12 nonce][16 salt][ciphertext+16 MAC] -> min 49 bytes
      if (encData.length < 49 || !_hasV3Magic(encData)) {
        return false;
      }

      final nativeDecrypted =
          KeyTitanNativeCore.instance?.decryptVault(encData, _passwordBytes);
      if (nativeDecrypted != null) {
        try {
          if (_isValidSqliteBytes(nativeDecrypted)) {
            await _loadDbFromBytes(nativeDecrypted);
            return true;
          }
        } finally {
          nativeDecrypted.fillRange(0, nativeDecrypted.length, 0);
        }
      }

      final nonce = encData.sublist(4, 16);
      final salt = encData.sublist(16, 32);
      final cipherPayload = encData.sublist(32);

      final keyBytes =
          await _deriveKeyArgon2id(_passwordBytes, Uint8List.fromList(salt));
      Uint8List? decrypted;
      try {
        decrypted = await _chaCha20Decrypt(keyBytes, nonce, cipherPayload);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }

      if (decrypted != null) {
        try {
          if (_isValidSqliteBytes(decrypted)) {
            await _loadDbFromBytes(decrypted);
            return true;
          }
        } finally {
          decrypted.fillRange(0, decrypted.length, 0);
        }
      }

      return false;
    } catch (e) {
      debugPrint('Decryption error: $e');
      return false;
    }
  }

  // Serialises the in-memory DB, encrypts it with ChaCha20-Poly1305 (v3),
  // and writes the file back to fileName.
  Future<bool> attemptEncrypt() async {
    if (_db == null || !_db!.isOpen) return false;

    try {
      final rawBytes = await _exportDbToBytes();
      try {
        final nativeEncrypted =
            KeyTitanNativeCore.instance?.encryptVault(rawBytes, _passwordBytes);
        if (nativeEncrypted != null) {
          try {
            await _writeVaultBytesAtomic(nativeEncrypted);
            return true;
          } finally {
            nativeEncrypted.fillRange(0, nativeEncrypted.length, 0);
          }
        }

        final salt = _secureRandomBytes(16);
        final nonce = _secureRandomBytes(12);

        final keyBytes = await _deriveKeyArgon2id(_passwordBytes, salt);
        final Uint8List cipherPayload;
        try {
          cipherPayload = await _chaCha20Encrypt(keyBytes, nonce, rawBytes);
        } finally {
          keyBytes.fillRange(0, keyBytes.length, 0);
        }

        // v3 layout: [4 magic "KTN3"][12 nonce][16 salt][ciphertext+16 MAC]
        final out = Uint8List(4 + 12 + 16 + cipherPayload.length);
        out.setRange(0, 4, _kV3Magic);
        out.setRange(4, 16, nonce);
        out.setRange(16, 32, salt);
        out.setRange(32, out.length, cipherPayload);

        await _writeVaultBytesAtomic(out);

        return true;
      } finally {
        rawBytes.fillRange(0, rawBytes.length, 0);
      }
    } catch (e) {
      debugPrint('Encryption error: $e');
      return false;
    }
  }

  Future<void> _writeVaultBytesAtomic(Uint8List bytes) async {
    final target = File(fileName);
    final dir = target.parent;
    await dir.create(recursive: true);

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
  // ChaCha20-Poly1305-AEAD helpers
  // ---------------------------------------------------------------------------

  static final _chacha20 = crypto.Chacha20.poly1305Aead();

  Future<Uint8List> _chaCha20Encrypt(
      Uint8List keyBytes, List<int> nonce, Uint8List plaintext) async {
    final secretKey = await _chacha20.newSecretKeyFromBytes(keyBytes);
    final secretBox = await _chacha20.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );
    // SecretBox layout: cipherText followed by 16-byte MAC
    return Uint8List.fromList(secretBox.cipherText + secretBox.mac.bytes);
  }

  /// Returns null if MAC verification fails.
  Future<Uint8List?> _chaCha20Decrypt(
      Uint8List keyBytes, List<int> nonce, List<int> cipherPayload) async {
    if (cipherPayload.length < 16) return null;
    final cipherText = cipherPayload.sublist(0, cipherPayload.length - 16);
    final macBytes = cipherPayload.sublist(cipherPayload.length - 16);

    final secretKey = await _chacha20.newSecretKeyFromBytes(keyBytes);
    final secretBox = crypto.SecretBox(
      cipherText,
      nonce: nonce,
      mac: crypto.Mac(macBytes),
    );
    try {
      final plain = await _chacha20.decrypt(secretBox, secretKey: secretKey);
      return Uint8List.fromList(plain);
    } on crypto.SecretBoxAuthenticationError {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Magic-byte detection
  // ---------------------------------------------------------------------------

  bool _hasV3Magic(Uint8List data) {
    if (data.length < 4) return false;
    for (int i = 0; i < 4; i++) {
      if (data[i] != _kV3Magic[i]) return false;
    }
    return true;
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
  // Validation
  // ---------------------------------------------------------------------------

  bool _isValidSqliteBytes(Uint8List bytes) {
    if (bytes.length < 16) return false;
    return utf8.decode(bytes.sublist(0, 16), allowMalformed: true) ==
        'SQLite format 3\u0000';
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

  Future<int> savePassword(keyTitanPass pass) async {
    final db = await _initDatabase();
    int catId = await getCategoryID(pass.category);
    if (catId == -1) catId = await insertCategory(pass.category);

    final encryptedField =
        await keyTitanPass.hencrypt(_passwordBytes, pass.displayPassword);

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
      return pass.id;
    } else {
      await db.update('password', data, where: 'id = ?', whereArgs: [pass.id]);
      await _pruneEmptyCategories(db);
      return pass.id;
    }
  }

  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (currentPassword.isEmpty || newPassword.isEmpty) return false;

    final db = await _initDatabase();
    final currentBytes = Uint8List.fromList(utf8.encode(currentPassword));
    final newBytes = Uint8List.fromList(utf8.encode(newPassword));
    final oldBytes = _passwordBytes;
    final updates = <_PasswordCipherUpdate>[];
    var dbUpdated = false;
    var newBytesOwnedByFile = false;

    try {
      if (!_constantTimeEquals(oldBytes, currentBytes)) return false;

      final rows = await db.query('password', columns: ['id', 'password']);
      for (final row in rows) {
        final id = row['id'] as int;
        final oldCipher = row['password']?.toString() ?? '';
        final plainText = await keyTitanPass.hdecrypt(oldBytes, oldCipher);
        if (plainText == keyTitanPass.decryptionError) return false;

        final newCipher = await keyTitanPass.hencrypt(newBytes, plainText);
        updates.add(_PasswordCipherUpdate(id, oldCipher, newCipher));
      }

      await _applyPasswordCipherUpdates(db, updates, useNewCipher: true);
      dbUpdated = true;

      _passwordBytes = newBytes;
      newBytesOwnedByFile = true;

      if (await attemptEncrypt()) {
        oldBytes.fillRange(0, oldBytes.length, 0);
        return true;
      }

      _passwordBytes = oldBytes;
      newBytesOwnedByFile = false;
      await _applyPasswordCipherUpdates(db, updates, useNewCipher: false);
      return false;
    } catch (e) {
      debugPrint('Password change error: $e');
      if (identical(_passwordBytes, newBytes)) {
        _passwordBytes = oldBytes;
        newBytesOwnedByFile = false;
      }
      if (dbUpdated) {
        try {
          await _applyPasswordCipherUpdates(db, updates, useNewCipher: false);
        } catch (rollbackError) {
          debugPrint('Password change rollback error: $rollbackError');
        }
      }
      return false;
    } finally {
      currentBytes.fillRange(0, currentBytes.length, 0);
      if (!newBytesOwnedByFile) {
        newBytes.fillRange(0, newBytes.length, 0);
      }
    }
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
    return db.insert('category', {'category': category},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> deletePassword(int id) async {
    final db = await _initDatabase();
    await db.delete('password', where: 'id = ?', whereArgs: [id]);
    await _pruneEmptyCategories(db);
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
  // layer. This prevents password values from sitting plainly in SQLite pages
  // while the vault is open, but it is not a defense against full process-memory
  // compromise because the master password also lives in process memory.
  // ---------------------------------------------------------------------------

  static const String _fieldCipherPrefix = 'c20p1';
  static const String decryptionError = '[Decryption Error]';
  static final _fieldCipher = crypto.Chacha20.poly1305Aead();

  static Uint8List _deriveFieldKey(Uint8List seedBytes) {
    final digest = dart_crypto.sha256.convert([
      ...utf8.encode('KeyTitan field encryption v1'),
      ...seedBytes,
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  static Future<String> hencrypt(Uint8List seedBytes, String plainText) async {
    if (plainText.isEmpty) return '';
    final nativeEncrypted =
        KeyTitanNativeCore.instance?.fieldEncrypt(seedBytes, plainText);
    if (nativeEncrypted != null) return nativeEncrypted;

    final nonce = _secureRandomBytes(12);
    final keyBytes = _deriveFieldKey(seedBytes);
    try {
      final secretKey = await _fieldCipher.newSecretKeyFromBytes(keyBytes);
      final box = await _fieldCipher.encrypt(
        utf8.encode(plainText),
        secretKey: secretKey,
        nonce: nonce,
      );
      final payload = Uint8List.fromList(box.cipherText + box.mac.bytes);
      return '$_fieldCipherPrefix:${base64.encode(nonce)}:${base64.encode(payload)}';
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }

  static Future<String> hdecrypt(Uint8List seedBytes, String cipherText) async {
    if (cipherText.isEmpty) return '';

    final nativeDecrypted =
        KeyTitanNativeCore.instance?.fieldDecrypt(seedBytes, cipherText);
    if (nativeDecrypted != null) return nativeDecrypted;

    if (!cipherText.startsWith('$_fieldCipherPrefix:')) {
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

      final keyBytes = _deriveFieldKey(seedBytes);
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
    final nativeUris = KeyTitanNativeCore.instance?.deriveUris(site);
    if (nativeUris != null) return nativeUris;

    final raw = site.trim();
    if (raw.isEmpty) return '[]';

    final values = <String>{raw};
    final lowerRaw = raw.toLowerCase();
    if (lowerRaw.startsWith('androidapp://') || lowerRaw.startsWith('app://')) {
      final packageName = lowerRaw.split('://').last.split('/').first;
      if (packageName.isNotEmpty) values.add(packageName);
      return jsonEncode(values.toList());
    }

    final parsed = raw.contains('://') ? Uri.tryParse(raw) : null;
    final host = parsed?.host.isNotEmpty == true
        ? parsed!.host.toLowerCase()
        : raw
            .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
            .split('/')
            .first
            .toLowerCase();

    if (host.isNotEmpty) {
      values.add(host);
      if (host.contains('.')) {
        values.add('https://$host');
        if (!host.startsWith('www.')) {
          values.add('https://www.$host');
        }
      }
    }

    return jsonEncode(values.toList());
  }
}
