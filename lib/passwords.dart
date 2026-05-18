// ignore_for_file: camel_case_types
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:typed_data/typed_buffers.dart';
import 'globals.dart';

// ---------------------------------------------------------------------------
// .ktn file format
// ---------------------------------------------------------------------------
// v2 (legacy):  [8-byte Salsa20 IV] [16-byte Argon2id salt] [ciphertext]
//   Key: Argon2id(memory=64MB, parallelism=2, iterations=3) → 32 bytes.
//   Supported for reading only — files are upgraded to v3 on next save.
//
// v3 (current): [4-byte magic "KTN3"] [12-byte ChaCha20 nonce]
//               [16-byte Argon2id salt] [ciphertext+16-byte Poly1305 MAC]
//   Key: Argon2id(memory=64MB, parallelism=2, iterations=3) → 32 bytes.
//   A fresh random nonce and salt are written on every save.
//
// attemptDecrypt detects v3 by the "KTN3" magic prefix; otherwise falls back
// to v2 Salsa20+Argon2id. Files opened as v2 are silently upgraded to v3 on
// the next save.
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
  final Uint8List _passwordBytes; // zeroed on dispose

  Database? _db;
  bool isEncrypted = true;

  passFile(this.fileName, String password)
      : _passwordBytes = Uint8List.fromList(utf8.encode(password));

  // Expose key material only for field-level decryption. Do not hold the
  // returned reference longer than the immediate call.
  Uint8List get passwordBytes => _passwordBytes;

  static passFile fromObject(Object? obj) => obj as passFile;

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
      'title TEXT, site TEXT, category_id INTEGER, username TEXT, password TEXT, '
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

  // Reads the .ktn file, decrypts it, and loads the result into an in-memory
  // SQLite database. Tries the current v3 format first, then falls back to v2.
  Future<bool> attemptDecrypt() async {
    try {
      final f = File(fileName);
      if (!await f.exists()) return false;
      final encData = await f.readAsBytes();

      // Detect v3 by magic prefix "KTN3".
      // Layout: [4 magic][12 nonce][16 salt][ciphertext+16 MAC] → min 49 bytes
      if (encData.length >= 49 && _hasV3Magic(encData)) {
        final nonce = encData.sublist(4, 16);
        final salt = encData.sublist(16, 32);
        final cipherPayload = encData.sublist(32);

        final keyBytes =
            await _deriveKeyArgon2id(_passwordBytes, Uint8List.fromList(salt));
        final decrypted =
            await _chaCha20Decrypt(keyBytes, nonce, cipherPayload);
        keyBytes.fillRange(0, keyBytes.length, 0);

        if (decrypted != null && _isValidSqliteBytes(decrypted)) {
          await _loadDbFromBytes(decrypted);
          isEncrypted = false;
          return true;
        }
        return false;
      }

      // Fallback: v2 Salsa20 + Argon2id.
      // Layout: [8 IV][16 salt][ciphertext] → min 25 bytes
      if (encData.length >= 25) {
        final iv = encrypt.IV(encData.sublist(0, 8));
        final salt = encData.sublist(8, 24);
        final cipherBytes = encrypt.Encrypted(encData.sublist(24));

        final keyBytes =
            await _deriveKeyArgon2id(_passwordBytes, Uint8List.fromList(salt));
        final decrypted = _salsa20Decrypt(keyBytes, iv, cipherBytes);
        keyBytes.fillRange(0, keyBytes.length, 0);

        if (_isValidSqliteBytes(decrypted)) {
          await _loadDbFromBytes(decrypted);
          isEncrypted = false;
          debugPrint(
              'Opened legacy v2 file — will upgrade to v3 on next save.');
          return true;
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

      final salt = _secureRandomBytes(16);
      final nonce = _secureRandomBytes(12);

      final keyBytes = await _deriveKeyArgon2id(_passwordBytes, salt);
      final cipherPayload = await _chaCha20Encrypt(keyBytes, nonce, rawBytes);
      keyBytes.fillRange(0, keyBytes.length, 0);

      // v3 layout: [4 magic "KTN3"][12 nonce][16 salt][ciphertext+16 MAC]
      final out = Uint8List(4 + 12 + 16 + cipherPayload.length);
      out.setRange(0, 4, _kV3Magic);
      out.setRange(4, 16, nonce);
      out.setRange(16, 32, salt);
      out.setRange(32, out.length, cipherPayload);

      await File(fileName).writeAsBytes(out);

      isEncrypted = true;
      return true;
    } catch (e) {
      debugPrint('Encryption error: $e');
      return false;
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
  // Legacy Salsa20 helpers (read-only, for v2 backward compatibility)
  // ---------------------------------------------------------------------------

  Uint8List _salsa20Decrypt(
          Uint8List k, encrypt.IV iv, encrypt.Encrypted blob) =>
      Uint8List.fromList(
        encrypt.Encrypter(encrypt.Salsa20(encrypt.Key(k)))
            .decryptBytes(blob, iv: iv),
      );

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
    await _withInMemorySqliteBytes(
      sqliteBytes,
      readOnly: true,
      action: (srcDb) async {
        final categories = srcDb.select(
          'SELECT id, category FROM category ORDER BY id ASC',
        );
        final passwords = srcDb.select(
          'SELECT id, title, site, category_id, username, password '
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
                },
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
        });
      },
    );
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
          'id, title, site, category_id, username, password'
          ') VALUES (?, ?, ?, ?, ?, ?)',
        );

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
          ]);
        }
        catStmt.close();
        passStmt.close();
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
      'title TEXT, site TEXT, category_id INTEGER, username TEXT, password TEXT, '
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
             A.username, A.password, A.category_id, B.category
      FROM password A
      JOIN category B ON A.category_id = B.id
      WHERE $col = ?
    ''', [category]);
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

// ---------------------------------------------------------------------------
// keyTitanPass — a single password entry
// ---------------------------------------------------------------------------

class keyTitanPass {
  int id;
  String title;
  String site;
  String category;
  String username;
  String displayPassword;

  keyTitanPass({
    this.id = -1,
    required this.title,
    required this.site,
    required this.category,
    required this.username,
    this.displayPassword = '',
  });

  // ---------------------------------------------------------------------------
  // Field-level ChaCha20-Poly1305 encryption
  //
  // Individual password fields are encrypted inside the SQLite DB as a second
  // layer. This prevents password values from sitting plainly in SQLite pages
  // while the vault is open, but it is not a defense against full process-memory
  // compromise because the master password also lives in process memory.
  // ---------------------------------------------------------------------------

  static const String _fieldCipherPrefix = 'c20p1';
  static final _fieldCipher = crypto.Chacha20.poly1305Aead();

  static Uint8List _deriveFieldKey(Uint8List seedBytes) {
    final digest = dart_crypto.sha256.convert([
      ...utf8.encode('KeyTitan field encryption v1'),
      ...seedBytes,
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  static Uint8List _deriveLegacyAesKey(Uint8List passBytes) {
    final key = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      key[i] = passBytes[i % passBytes.length];
    }
    return key;
  }

  static Future<String> hencrypt(Uint8List seedBytes, String plainText) async {
    if (plainText.isEmpty) return '';
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
    if (cipherText.startsWith('$_fieldCipherPrefix:')) {
      return _hdecryptChaCha20(seedBytes, cipherText);
    }
    return _hdecryptLegacyAesCbc(seedBytes, cipherText);
  }

  static Future<String> _hdecryptChaCha20(
    Uint8List seedBytes,
    String cipherText,
  ) async {
    try {
      final parts = cipherText.split(':');
      if (parts.length != 3) return '[Decryption Error]';
      final nonce = base64.decode(parts[1]);
      final payload = base64.decode(parts[2]);
      if (nonce.length != 12 || payload.length < 16) {
        return '[Decryption Error]';
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
      return '[Decryption Error]';
    }
  }

  static String _hdecryptLegacyAesCbc(
    Uint8List seedBytes,
    String cipherText,
  ) {
    try {
      final parts = cipherText.split(':');
      if (parts.length != 2) return '[Decryption Error]';
      final iv = encrypt.IV.fromBase64(parts[0]);
      final encrypted = encrypt.Encrypted.fromBase64(parts[1]);
      final keyBytes = _deriveLegacyAesKey(seedBytes);
      try {
        final key = encrypt.Key(keyBytes);
        final encrypter =
            encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
        return encrypter.decrypt(encrypted, iv: iv);
      } finally {
        keyBytes.fillRange(0, keyBytes.length, 0);
      }
    } catch (_) {
      return '[Decryption Error]';
    }
  }

  static String genPassword(Complexity complexity, int length) {
    final alphabet = complexity.getAlphabet();
    final rand = Random.secure();
    return List.generate(length, (_) => alphabet[rand.nextInt(alphabet.length)])
        .join();
  }
}
