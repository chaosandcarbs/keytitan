// ignore_for_file: camel_case_types
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:sqflite/sqflite.dart';
import 'globals.dart';

class passFile {
  final String fileName; // The .ktn encrypted file
  final String password;
  File? _sqlFile;        // The temporary .sqlite file
  Database? _db;         // Singleton database instance
  bool isEncrypted = true;

  passFile(this.fileName, this.password);

  static passFile fromObject(Object? obj) => obj as passFile;

  // --- File & DB Management ---

  Future<void> dispose() async {
    await _closeDB();
    if (_sqlFile != null && await _sqlFile!.exists()) {
      try {
        await _sqlFile!.delete();
      } catch (e) {
        debugPrint('Cleanup error: $e');
      }
    }
  }

  Future<void> _closeDB() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }

  void newSQLFile() {
    try {
      _sqlFile = File('$fileName.sqlite');
      if (!_sqlFile!.existsSync()) {
        _sqlFile!.createSync(recursive: true);
      }
      _initDatabase();
    } catch (e) {
      debugPrint('Error creating SQL file: $e');
    }
  }

  Future<Database> _initDatabase() async {
    if (_db != null && _db!.isOpen) return _db!;
    
    _db = await openDatabase(
      _sqlFile?.path ?? '$fileName.sqlite',
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE category(id INTEGER PRIMARY KEY, category TEXT UNIQUE);');
        await db.execute('''
          CREATE TABLE password(
            id INTEGER PRIMARY KEY, 
            title TEXT, 
            site TEXT, 
            category_id INTEGER, 
            username TEXT, 
            password TEXT, 
            FOREIGN KEY(category_id) REFERENCES category(id)
          );
        ''');
      },
    );
    return _db!;
  }

  // --- Encryption / Decryption ---

  Future<bool> attemptDecrypt() async {
    try {
      final File encFile = File(fileName);
      if (!await encFile.exists()) return false;
      
      final Uint8List encData = await encFile.readAsBytes();
      if (encData.length < 8) return false;

      final iv = encrypt.IV(encData.sublist(0, 8));
      final encryptedBlob = encrypt.Encrypted(encData.sublist(8));

      final key = encrypt.Key.fromUtf8(_derive32ByteKey(password));
      final encrypter = encrypt.Encrypter(encrypt.Salsa20(key));

      final decrypted = encrypter.decryptBytes(encryptedBlob, iv: iv);
      
      _sqlFile = File('$fileName.sqlite');
      await _sqlFile!.writeAsBytes(decrypted);
      if (await isValidSqliteHeader(_sqlFile!)){
        isEncrypted = false;
        return true;
      }
      else {
        isEncrypted = true;
        _sqlFile!.deleteSync();
        _sqlFile = null;
        return false;
      }
    } catch (e) {
      debugPrint('Decryption failed: $e');
      return false;
    }
  }

  Future<bool> attemptEncrypt() async {
    if (_sqlFile == null || !await _sqlFile!.exists()) return false;

    try {
      await _closeDB(); // Ensure DB is closed before reading bytes
      final rawBytes = await _sqlFile!.readAsBytes();
      final iv = encrypt.IV.fromSecureRandom(8);
      
      final key = encrypt.Key.fromUtf8(_derive32ByteKey(password));
      final encrypter = encrypt.Encrypter(encrypt.Salsa20(key));

      final encrypted = encrypter.encryptBytes(rawBytes, iv: iv);
      
      final File encFile = File(fileName);
      await encFile.writeAsBytes(iv.bytes + encrypted.bytes);
      
      isEncrypted = true;
      return true;
    } catch (e) {
      debugPrint('Encryption failed: $e');
      return false;
    }
  }

  String _derive32ByteKey(String pass) {
    return pass.padRight(32, pass).substring(0, 32);
  }

  Future<bool> isValidSqliteHeader(File file) async {
    if (!await file.exists()) return false;

    try {
      // Open a random access file to read only the first 16 bytes
      final raf = await file.open(mode: FileMode.read);
      final headerBytes = await raf.read(16);
      await raf.close();

      // The standard SQLite 3 magic string
      const magicString = "SQLite format 3\u0000";
      final actualString = utf8.decode(headerBytes, allowMalformed: true);

      return actualString == magicString;
    } catch (e) {
      return false;
    }
  }

  // --- Database Operations ---

  Future<List<Map<String, dynamic>>> getCategories() async {
    final db = await _initDatabase();
    return await db.query('category', orderBy: 'category ASC');
  }

  Future<List<Map<String, dynamic>>> getPasswordsByCategory(dynamic category) async {
    final db = await _initDatabase();
    final String column = (category is String) ? 'B.category' : 'B.id';
    
    return await db.rawQuery('''
      SELECT A.*, B.category 
      FROM password A 
      JOIN category B ON A.category_id = B.id 
      WHERE $column = ?
    ''', [category]);
  }

  Future<int> savePassword(keyTitanPass pass) async {
    final db = await _initDatabase();
    
    int catId = await getCategoryID(pass.category);
    if (catId == -1) catId = await insertCategory(pass.category);

    // Re-encrypt the password using a stable seed (the master password) 
    // instead of the record ID which changes on first save.
    String encryptedField = keyTitanPass.hencrypt(password, pass.displayPassword);

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
      await _removeUnusedCategories(db);
      return pass.id;
    }
  }

  Future<int> getCategoryID(String category) async {
    final db = await _initDatabase();
    final res = await db.query('category', where: 'category = ?', whereArgs: [category]);
    return res.isNotEmpty ? res.first['id'] as int : -1;
  }

  Future<int> insertCategory(String category) async {
    final db = await _initDatabase();
    return await db.insert('category', {'category': category}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> deletePassword(int id) async {
    final db = await _initDatabase();
    await db.delete('password', where: 'id = ?', whereArgs: [id]);
    await _removeUnusedCategories(db);
  }

  Future<void> _removeUnusedCategories(Database db) async {
    debugPrint('Removing unused categories');
    await db.transaction((txn) async {
      List<Map> idlist = await txn.rawQuery('SELECT A.id FROM category A LEFT JOIN password B ON B.category_id = A.id WHERE B.id IS NULL;');
      for(int i = 0; i < idlist.length; i++){
        await txn.delete('category', where: 'id = ?', whereArgs: [idlist[i]['id']]);
      }
    });
  }
}

class keyTitanPass {
  int id;
  String title;
  String site;
  String category;
  String username;
  String displayPassword; // Used for UI and temporary storage

  keyTitanPass({
    this.id = -1,
    required this.title,
    required this.site,
    required this.category,
    required this.username,
    this.displayPassword = '',
  });

  // --- Internal Helper Encryption (Field Level) ---

  static String hencrypt(String seed, String plainText) {
    if (plainText.isEmpty) return '';
    final iv = encrypt.IV.fromSecureRandom(16);
    final key = encrypt.Key.fromUtf8(seed.padRight(32, seed).substring(0, 32));
    final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
    
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${base64.encode(iv.bytes)}:${encrypted.base64}';
  }

  static String hdecrypt(String seed, String cipherText) {
    if (cipherText.isEmpty) return '';
    try {
      final parts = cipherText.split(':');
      final iv = encrypt.IV.fromBase64(parts[0]);
      final encrypted = encrypt.Encrypted.fromBase64(parts[1]);
      
      final key = encrypt.Key.fromUtf8(seed.padRight(32, seed).substring(0, 32));
      final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));
      
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      return '[Decryption Error]';
    }
  }

  static String genPassword(Complexity complexity, int  length) {
    final alphabet = complexity.getAlphabet();
    final rand = Random.secure();
    return List.generate(length, (_) => alphabet[rand.nextInt(alphabet.length)]).join();
  }
}