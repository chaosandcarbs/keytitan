// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:math';
import 'globals.dart';
import 'package:flutter/material.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:sqflite/utils/utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';



class passFile {
  String? fileName;
  String? password;
  File? _sqlFile;
  bool isEncrypted = false;
  Map<String,List<keyTitanPass>>? _passList;
  
  passFile(this.fileName, this.password);

  static passFile passObj(Object? obj) {  
    passFile tmp = obj as passFile;
    return tmp;
  }

  void closeFiles() async{
    await _closeDB();
    await _deleteTempSqlFile();
  }

  Future<void> _closeDB() async {
    Database db = await _initKeyTitanDB(); 
    while(db.isOpen) {
      await db.close();
    }
  }

  Future<void> _deleteTempSqlFile() async {    
    try{
      //_sqlFile?.deleteSync();
      await _sqlFile!.delete();
    }
    catch(e){
      debugPrint('Error: $e');
    }
  }

  bool fileExists() {
    if(fileName == null){
      return false;
    }
    else if(_sqlFile == null){
      return false;
    }
    else{
      //if file exists, we have an existing keytitan file
      //   if only sqlfile exists, it's a new file
      return (File(fileName!).existsSync() | _sqlFile!.existsSync());
    }
  }

  void newSQLFile() {
    WidgetsFlutterBinding.ensureInitialized();
    try{
      _sqlFile = File('${fileName!}.sqlite');
      debugPrint('Touching file ${_sqlFile}');
      // use exclusive=false; do not modify existing files
      _sqlFile!.createSync(exclusive: false);
      // ignore: unused_local_variable
      Future<Database> db = _initKeyTitanDB();
    }
    catch(except) { debugPrint(except.toString()); }
  }

  Future<bool> attemptDecrypt() async {
    if(fileName == null || password == null)
    {
      return false;
    }
    try {
      File encFile = File(fileName!);
      Uint8List encText = encFile.readAsBytesSync();
      var iv = base64Encode(encText.sublist(0, 8)); //first 8 are the iv
      //encText.removeRange(0, 8);       //pop off iv

      String keystr = '';
      for(int i = 0; i < 32; i++){
        keystr = keystr+password![i % password!.length];
      }

      // decrypt now uses Salsa20
      encrypt.Encrypted encBlob = encrypt.Encrypted(encText.sublist(8));
      final key = encrypt.Key.fromUtf8(keystr);
      //final encryptor = encrypt.Encrypter(encrypt.AES(key, mode:encrypt.AESMode.cbc));
      final encryptor = encrypt.Encrypter(encrypt.Salsa20(key));
      final ivector = encrypt.IV.fromBase64(iv);
      var decrypted = encryptor.decryptBytes(encBlob, iv: ivector);
      _sqlFile = File('${fileName!}.sqlite');
      _sqlFile?.writeAsBytesSync(decrypted);
    }
    on Exception catch (exc) {
      debugPrint(exc.toString());
      return false;
    }
    isEncrypted = false;
    return true;
  }

  Future<bool> attemptEncrypt() async {
    if(fileName == null || password == null || _sqlFile == null)
    {
      return false;
    }
    try {
      // variable for finished file
      File encFile = File(fileName!);
      //_sqlFile = File('${fileName!}.sqlite');

      // set up the iv
      var rng = Random.secure();
      List<int> ivlist = [];
      for(int i = 0; i < 8; i++){
        ivlist.add(rng.nextInt(10));
      }

      String keystr = '';
      for(int i = 0; i < 32; i++){
        keystr = keystr+password![i % password!.length];
      }

      // set up password/key, encryption object
      //final encrypt.Encrypted decBlob = encrypt.Encrypted(await _sqlFile!.readAsBytes());
      final key = encrypt.Key.fromUtf8(keystr);
      //final encryptor = encrypt.Encrypter(encrypt.AES(key, mode:encrypt.AESMode.cbc));
      final encryptor = encrypt.Salsa20(key);


      // encrypt now uses Salsa20
      final ivector = encrypt.IV.fromUtf8(ivlist.join());
      //var encrypted = encryptor.encryptBytes(_sqlFile!.readAsBytesSync(), iv: ivector);
      var encrypted = encryptor.encrypt(_sqlFile!.readAsBytesSync(), iv: ivector);
      encFile.writeAsBytesSync(ivector.bytes + encrypted.bytes);
      //_sqlFile?.deleteSync();
    }
    on Exception catch (exc) {
      debugPrint(exc.toString());
      return false;
    }
    isEncrypted = true;
    return true;
  }

  final String _createPassTable = 'CREATE TABLE password(id INTEGER PRIMARY KEY, title TEXT, site TEXT, category_id INTEGER, username TEXT, password BLOB, FOREIGN KEY(category_id) REFERENCES category(id));';
  final String _createCatTable = 'CREATE TABLE category(id INTEGER PRIMARY KEY, category TEXT);';

  Future<Database> _initKeyTitanDB() async {
    WidgetsFlutterBinding.ensureInitialized();
    return await openDatabase(
      _sqlFile!.path,
      onCreate: (db, version) {
        debugPrint('KeyTitan database not found; initializing');
        //_nukeItFromOrbit(db);
        return _createTables(db);
      },
      version: 2,
    );
  }

  Future<void> _createTables(Database db) async {
    WidgetsFlutterBinding.ensureInitialized();
    await db.execute(_createCatTable);
    await db.execute(_createPassTable);
  }

  Future<void> _nukeItFromOrbit(Database db) async {
    WidgetsFlutterBinding.ensureInitialized();
    debugPrint('Nuking DB From Orbit');
    await db.execute('DROP TABLE IF EXISTS password');
    await db.execute('DROP TABLE IF EXISTS category');
  }

  Future<List> getPasswordsByCategory(var category) async {
    final db = await _initKeyTitanDB();
    
    // Check if category is String or ID and use appropriate WHERE clause
    String column = (category is String) ? 'B.category' : 'B.id';
    
    // Using ? placeholders for the category value
    final passList = await db.rawQuery(
      'SELECT A.ID, A.title, A.site, B.category, A.username, A.password '
      'FROM password A '
      'INNER JOIN category B ON A.category_id = B.id '
      'WHERE $column = ?;',
      [category]
    );
    return passList;
  }

  Future<int> insertPassword(keyTitanPass password) async {
    int catID = await getCategoryID(password.category);
    if (catID == -1) {
      catID = await insertCategory(password.category);
    }
    
    final db = await _initKeyTitanDB();
    return await db.transaction((txn) async {
      // 1. Insert the record with placeholders
      final id = await txn.rawInsert(
        'INSERT INTO password(title, site, category_id, username, password) VALUES (?, ?, ?, ?, ?)',
        [password.title, password.site, catID, password.username, password._password] // Use the raw _password field
      );
      
      // 2. Update the local object ID
      password.updateID(id);
      
      // Note: You previously had an extra UPDATE here. Since we use the raw _password
      // in the insert above, that extra step is no longer needed.
      
      return id;
    });
  }

  Future<void> updatePassword(keyTitanPass password) async {
    int catID = await getCategoryID(password.category);
    final db = await _initKeyTitanDB();
    
    await db.transaction((txn) async {
      int count = await txn.rawUpdate(
        'UPDATE password SET title = ?, site = ?, category_id = ?, username = ?, password = ? WHERE id = ?',
        [password.title, password.site, catID, password.username, password._password, password.id]
      );
      debugPrint('Updated: $count');
    });
    
    // It's safer to await this to ensure DB consistency
    await _removeUnusedCategories(db);
  }

  Future<void> _removeUnusedCategories(Database db) async {
    debugPrint('Removing unused categories');
    await db.transaction((txn) async {
      // Find categories that have no linked passwords
      List<Map<String, dynamic>> idlist = await txn.rawQuery(
        'SELECT A.id FROM category A LEFT JOIN password B ON B.category_id = A.id WHERE B.id IS NULL;'
      );
      
      for (var row in idlist) {
        await txn.delete('category', where: 'id = ?', whereArgs: [row['id']]);
      }
    });
  }

  Future<void> deletePassword(int id) async {
    debugPrint('Deleting Password');
    final db = await _initKeyTitanDB();
    await db.transaction((txn) async {
      await txn.delete('password', where: 'id = ?', whereArgs: [id]);
    });
    await _removeUnusedCategories(db);
  }

  Future<void> deleteCategory(int id) async {
    final db = await _initKeyTitanDB();
    await db.delete('category', where: 'id = ?', whereArgs: [id]);
  }


  Future<int> getCategoryID(String category) async {
    final db = await _initKeyTitanDB();
  
    final idlist = await db.rawQuery(
      'SELECT id FROM category WHERE category = ?',
      [category] 
    );

    if (idlist.isNotEmpty) {
      return idlist.first['id'] as int;
    }
    
    return -1;
  }

  Future<List> getCategories() async {
    final db = await _initKeyTitanDB();

    final catlist = await db.rawQuery(
      'SELECT * FROM category;'
    );

    return catlist;
  }

  Future<int> insertCategory(String category) async {
    final db = await _initKeyTitanDB();

    final id = await db.rawInsert(
      'INSERT INTO category(category) VALUES(?)',
      [category] 
    );

    return id;
  }
}



class keyTitanPass {
  int id;
  String title = '';
  String site = '';
  String category = '';
  String username = '';
  String _password = '';

  String get password {
    return hdecrypt(id.toString(), _password);
  }
  set password (String newPass) {
    _password = hencrypt(id.toString(), newPass);
  }

  keyTitanPass({
    this.id=-1,
    required this.title,
    required this.site,
    required this.category,
    required this.username,
    password = ' '
}): _password = hencrypt(id.toString(), password);

  static String genPassword(Complexity comp, int pwLength) {
    String alphabet = comp.alphabet;
    String newPass = '';
    var rng = Random.secure();
    for(int i = 0; i < pwLength; i++) {
      newPass += alphabet[rng.nextInt(alphabet.length)];
    }
    return newPass;
  }

  void updateID(int newID) {
    debugPrint('Old ID  : $id');
    debugPrint('Old Pass: $password');
    String tPass = password;
    id = newID;
    password = tPass;
    tPass = '';
    debugPrint('New ID  : $newID');
    debugPrint('New Pass: $password');
  }

  Map<String,Object> toMap() {
    return {
      'id':id,
      'title':title,
      'site':site,
      'category':category,
      'username':username,
      'password':password
    };
  }

  static String hencrypt(String pass, String toEncrypt) {
    encrypt.Encrypted encString;
    String ivlist = '';
    try {
      // set up the iv
      var rng = Random.secure();
      for(int i = 0; i < 16; i++){
        ivlist = ivlist+(rng.nextInt(10).toString());
      }
      String keystr = '';
      for(int i = 0; i < 32; i++){
        keystr = keystr+pass[i % pass.length];
      }
      final key = encrypt.Key.fromUtf8(keystr);
      final encryptor = encrypt.Encrypter(encrypt.AES(key, mode:encrypt.AESMode.cbc));
      // encrypt AES, CBC
      final ivector = encrypt.IV.fromUtf8(ivlist.toString());
      debugPrint('IV: ${ivector.base64.toString()}');
      encString = encryptor.encrypt(toEncrypt, iv: ivector);
    }
    on Exception catch (exc) {
      debugPrint(exc.toString());
      return '';
    }
    return '${ivlist.toString()}${encString.base64}';
  }

  static String hdecrypt(String pass, String toDecrypt) {
    encrypt.Encrypted encBlob;
    String decrypted = '';
    try {
      var iv = toDecrypt.substring(0,16);
      String tdec = '';
      for(int i = 16; i < toDecrypt.length; i++){ tdec = tdec + toDecrypt[i];}
      encBlob = encrypt.Encrypted(Uint8List.fromList(Base64Codec().decode(tdec)));
      String keystr = '';
      for(int i = 0; i < 32; i++){
        keystr = keystr+pass[i % pass.length];
      }
      // decrypt AES, CBC
      final key = encrypt.Key.fromUtf8(keystr);
      final encryptor = encrypt.Encrypter(encrypt.AES(key, mode:encrypt.AESMode.cbc));
      final ivector = encrypt.IV.fromUtf8(iv);
      decrypted = encryptor.decrypt(encBlob, iv: ivector);
    }
    on Exception catch (exc) {
      debugPrint(exc.toString());
      return decrypted;
    }
    return decrypted;
  }
}
