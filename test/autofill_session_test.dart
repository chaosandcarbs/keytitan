import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/autofill_session.dart';
import 'package:keytitan/passwords.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('explicit autofill destinations retain scheme, port and app certificate',
      () {
    for (final uri in [
      'http://example.com',
      'https://example.com:8443/login',
      'androidapp://com.example.app?sha256_cert=${'A' * 64}'
    ]) {
      expect(jsonDecode(keyTitanPass.deriveUris(uri)), [uri]);
    }
  });

  test(
      'private autofill session unlocks, saves durably and rejects stale release',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_autofill_');
    final file = File('${dir.path}/vault.ktn');
    final original = passFile(file.path, 'test-master-password');
    final session = AutofillVaultSession();
    final reopened = AutofillVaultSession();
    try {
      await original.newSQLFile();
      await original.savePassword(keyTitanPass(
          title: 'First',
          site: 'https://example.com',
          category: 'Autofill',
          username: 'alice',
          displayPassword: 'first-secret'));
      expect(await original.attemptEncrypt(), isTrue);
      await original.dispose();

      expect(await session.unlock(file.path, 'wrong-password'), isFalse);
      expect(await session.unlock(file.path, 'test-master-password'), isTrue);
      final first = (await session.entries()).single;
      expect(first['password'], isNot('first-secret'));
      expect(await session.password(first), 'first-secret');
      final id = await session.save(keyTitanPass(
          title: 'Second',
          site: 'https://other.example.com:8443',
          category: 'Autofill',
          username: 'bob',
          displayPassword: 'second-secret'));
      await session.ensureCurrent();
      expect(await reopened.unlock(file.path, 'test-master-password'), isTrue);
      final second =
          (await reopened.entries()).firstWhere((row) => row['id'] == id);
      expect(await reopened.password(second), 'second-secret');

      await reopened.save(keyTitanPass(
          id: id,
          title: 'Second',
          site: 'https://other.example.com:8443',
          category: 'Autofill',
          username: 'bob',
          displayPassword: 'changed-secret'));
      await expectLater(session.password(first), throwsStateError);
      await expectLater(
          session.save(keyTitanPass(
              title: 'Stale',
              site: 'https://example.com',
              category: 'Autofill',
              username: 'alice',
              displayPassword: 'must-not-save')),
          throwsStateError);
      await session.close();
      expect(await session.unlock(file.path, 'test-master-password'), isFalse);
    } finally {
      await original.dispose();
      await session.close();
      await reopened.close();
      await dir.delete(recursive: true);
    }
  });

  test('cancellation during unlock cannot resurrect a vault session', () async {
    final dir =
        await Directory.systemTemp.createTemp('keytitan_autofill_cancel_');
    final file = passFile('${dir.path}/vault.ktn', 'master-password');
    final session = AutofillVaultSession();
    try {
      await file.newSQLFile();
      expect(await file.attemptEncrypt(), isTrue);
      await file.dispose();
      final pending = session.unlock(file.fileName, 'master-password');
      await session.close();
      expect(await pending, isFalse);
      expect(() => session.vault, throwsStateError);
    } finally {
      await file.dispose();
      await session.close();
      await dir.delete(recursive: true);
    }
  });
}
