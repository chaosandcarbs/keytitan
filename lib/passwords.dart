// ignore_for_file: camel_case_types
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'globals.dart';

// ---------------------------------------------------------------------------
// .ktn file format
// ---------------------------------------------------------------------------
// v1 (legacy):  [8-byte Salsa20 IV] [ciphertext]
//   Key: naive byte-repeat padding to 32 bytes — no KDF.
//
// v2 (current): [8-byte Salsa20 IV] [16-byte Argon2id salt] [ciphertext]
//   Key: Argon2id(memory=64MB, parallelism=2, iterations=3) → 32 bytes.
//   A fresh random salt is written on every save, so the derived key
//   changes even when the master password doesn't.
//
// attemptDecrypt tries v2 first. If the decrypted bytes don't carry a valid
// SQLite header it retries as v1, which upgrades old files on the next save.
// ---------------------------------------------------------------------------

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

  // Legacy v1 key derivation — kept only for reading old files.
  Uint8List _deriveKeyLegacy(Uint8List passBytes) {
    final key = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      key[i] = passBytes[i % passBytes.length];
    }
    return key;
  }

  // ---------------------------------------------------------------------------
  // Encrypt / Decrypt
  // ---------------------------------------------------------------------------

  // Reads the .ktn file, decrypts it, and loads the result into an in-memory
  // SQLite database. Tries the current v2 format first, then falls back to v1.
  Future<bool> attemptDecrypt() async {
    try {
      final f = File(fileName);
      if (!await f.exists()) return false;
      final encData = await f.readAsBytes();

      // Try v2 (Argon2id) — minimum: 8 (IV) + 16 (salt) + 1 byte = 25
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
          return true;
        }
      }

      // Fallback to v1 (legacy key padding).
      if (encData.length >= 9) {
        final iv = encrypt.IV(encData.sublist(0, 8));
        final cipherBytes = encrypt.Encrypted(encData.sublist(8));

        final keyBytes = _deriveKeyLegacy(_passwordBytes);
        final decrypted = _salsa20Decrypt(keyBytes, iv, cipherBytes);
        keyBytes.fillRange(0, keyBytes.length, 0);

        if (_isValidSqliteBytes(decrypted)) {
          await _loadDbFromBytes(decrypted);
          isEncrypted = false;
          debugPrint('Opened legacy v1 file — will upgrade on next save.');
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Decryption error: $e');
      return false;
    }
  }

  // Serialises the in-memory DB, encrypts it with a fresh Argon2id-derived
  // key, and writes the v2 file back to fileName.
  Future<bool> attemptEncrypt() async {
    if (_db == null || !_db!.isOpen) return false;

    try {
      final rawBytes = await _exportDbToBytes();

      final salt = Uint8List.fromList(
        List.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final iv = encrypt.IV.fromSecureRandom(8);

      final keyBytes = await _deriveKeyArgon2id(_passwordBytes, salt);
      final encrypted = _salsa20Encrypt(keyBytes, iv, rawBytes);
      keyBytes.fillRange(0, keyBytes.length, 0);

      // v2 layout: [8-byte IV][16-byte salt][ciphertext]
      await File(fileName).writeAsBytes(iv.bytes + salt + encrypted.bytes);

      isEncrypted = true;
      return true;
    } catch (e) {
      debugPrint('Encryption error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Salsa20 helpers
  // ---------------------------------------------------------------------------

  Uint8List _salsa20Decrypt(
          Uint8List k, encrypt.IV iv, encrypt.Encrypted blob) =>
      Uint8List.fromList(
        encrypt.Encrypter(encrypt.Salsa20(encrypt.Key(k)))
            .decryptBytes(blob, iv: iv),
      );

  encrypt.Encrypted _salsa20Encrypt(
          Uint8List k, encrypt.IV iv, Uint8List plain) =>
      encrypt.Encrypter(encrypt.Salsa20(encrypt.Key(k)))
          .encryptBytes(plain, iv: iv);

  // ---------------------------------------------------------------------------
  // Temp file helpers
  // ---------------------------------------------------------------------------

  // Staging files for DB serialisation go in the system temp directory, which
  // is always writable on every platform.
  Future<String> _tempFilePath(String suffix) async {
    final tmp = await getTemporaryDirectory();
    final id = DateTime.now().microsecondsSinceEpoch;
    return p.join(tmp.path, 'kt_$id$suffix');
  }

  // ---------------------------------------------------------------------------
  // In-memory DB serialisation
  // ---------------------------------------------------------------------------

  Future<void> _loadDbFromBytes(Uint8List sqliteBytes) async {
    final tempPath = await _tempFilePath('.import.sqlite');
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsBytes(sqliteBytes);

      final srcDb = await databaseFactoryFfi.openDatabase(
        tempPath,
        options: OpenDatabaseOptions(readOnly: true),
      );

      await _closeDb();
      _db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
      );

      final categories = await srcDb.query('category');
      final passwords = await srcDb.query('password');
      await srcDb.close();

      await _db!.transaction((txn) async {
        for (final row in categories) {
          await txn.insert('category', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final row in passwords) {
          await txn.insert('password', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (e) {
          debugPrint('Failed to delete import staging file: $e');
        }
      }
    }
  }

  Future<Uint8List> _exportDbToBytes() async {
    final tempPath = await _tempFilePath('.export.sqlite');
    final tempFile = File(tempPath);
    try {
      final dstDb = await databaseFactoryFfi.openDatabase(
        tempPath,
        options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
      );

      final categories = await _db!.query('category');
      final passwords = await _db!.query('password');

      await dstDb.transaction((txn) async {
        for (final row in categories) {
          await txn.insert('category', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final row in passwords) {
          await txn.insert('password', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
      await dstDb.close();

      return await tempFile.readAsBytes();
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (e) {
          debugPrint('Failed to delete export staging file: $e');
        }
      }
    }
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
        keyTitanPass.hencrypt(_passwordBytes, pass.displayPassword);

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
  // Field-level AES-CBC encryption
  //
  // Individual password fields are encrypted inside the SQLite DB as a second
  // layer. The key derivation here is lightweight (byte-repeat) because the
  // heavy Argon2id work already happened at the file-container level.
  // ---------------------------------------------------------------------------

  static Uint8List _deriveAesKey(Uint8List passBytes) {
    final key = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      key[i] = passBytes[i % passBytes.length];
    }
    return key;
  }

  static String hencrypt(Uint8List seedBytes, String plainText) {
    if (plainText.isEmpty) return '';
    final iv = encrypt.IV.fromSecureRandom(16);
    final key = encrypt.Key(_deriveAesKey(seedBytes));
    final encrypter =
        encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${base64.encode(iv.bytes)}:${encrypted.base64}';
  }

  static String hdecrypt(Uint8List seedBytes, String cipherText) {
    if (cipherText.isEmpty) return '';
    try {
      final parts = cipherText.split(':');
      final iv = encrypt.IV.fromBase64(parts[0]);
      final encrypted = encrypt.Encrypted.fromBase64(parts[1]);
      final key = encrypt.Key(_deriveAesKey(seedBytes));
      final encrypter =
          encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
      return encrypter.decrypt(encrypted, iv: iv);
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
