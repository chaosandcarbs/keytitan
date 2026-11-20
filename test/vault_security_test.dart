import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/passwords.dart';
import 'package:keytitan/secstore.dart';
import 'package:keytitan/vault_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

keyTitanPass _entry(String secret, {int id = -1}) => keyTitanPass(
  id: id,
  title: 'Email',
  site: 'https://example.com',
  category: 'General',
  username: 'alice',
  displayPassword: secret,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('new vault wraps its key before its first save', () async {
    final dir = await Directory.systemTemp.createTemp('kt-new-envelope-');
    final vault = passFile('${dir.path}/vault.ktn', 'synthetic-master');
    final reopened = passFile(vault.fileName, 'synthetic-master');
    try {
      await vault.newSQLFile();
      expect(vault.autofillVaultId, isNotNull);
      expect(await File(vault.fileName).exists(), isFalse);
      expect(await vault.attemptEncrypt(), isTrue);
      expect(await reopened.attemptDecrypt(), isTrue);
    } finally {
      await vault.dispose();
      await reopened.dispose();
      await dir.delete(recursive: true);
    }
  });

  test(
    'stale desktop writer cannot revert a master-password rotation',
    () async {
      final dir = await Directory.systemTemp.createTemp('kt-stale-');
      final file = File('${dir.path}/vault.ktn');
      final first = passFile(file.path, 'old-password');
      final stale = passFile(file.path, 'old-password');
      final oldAttempt = passFile(file.path, 'old-password');
      final newAttempt = passFile(file.path, 'new-password');
      try {
        await first.newSQLFile();
        await first.savePassword(_entry('original'));
        expect(await first.attemptEncrypt(), isTrue);
        expect(await stale.attemptDecrypt(), isTrue);
        expect(
          await first.changeMasterPassword(
            currentPassword: 'old-password',
            newPassword: 'new-password',
          ),
          isTrue,
        );
        final committed = await file.readAsBytes();
        await stale.savePassword(_entry('stale-edit'));
        expect(await stale.attemptEncrypt(), isFalse);
        expect(stale.needsSave, isTrue);
        expect(await file.readAsBytes(), committed);
        expect(await oldAttempt.attemptDecrypt(), isFalse);
        expect(await newAttempt.attemptDecrypt(), isTrue);
      } finally {
        await first.dispose();
        await stale.dispose();
        await oldAttempt.dispose();
        await newAttempt.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'sealed pending changes require authentication and remain stale',
    () async {
      final dir = await Directory.systemTemp.createTemp('kt-recover-');
      final file = File('${dir.path}/vault.ktn');
      final pending = passFile(file.path, 'old-password');
      final newer = passFile(file.path, 'old-password');
      try {
        await pending.newSQLFile();
        await pending.savePassword(_entry('original'));
        expect(await pending.attemptEncrypt(), isTrue);
        expect(await newer.attemptDecrypt(), isTrue);
        final row = (await pending.getPasswordsByCategory('General')).single;
        await pending.savePassword(
          _entry('unsaved-secret', id: row['id'] as int),
        );
        expect(
          await newer.changeMasterPassword(
            currentPassword: 'old-password',
            newPassword: 'new-password',
          ),
          isTrue,
        );
        final committed = await file.readAsBytes();
        pending.lockAccess();
        expect(await pending.attemptEncrypt(), isFalse);
        expect(await pending.suspendForRecovery(), isTrue);
        expect(pending.isSuspended, isTrue);
        expect(pending.autofillVaultId, isNull);
        await expectLater(
          pending.getCategories(),
          throwsA(isA<VaultLockedException>()),
        );
        await expectLater(
          pending.decryptPassword(row['password'] as String),
          throwsA(isA<VaultLockedException>()),
        );
        expect(
          () => pending.savePassword(_entry('forbidden')),
          throwsA(isA<VaultLockedException>()),
        );
        expect(await pending.resumeAfterFailedSave('wrong'), isFalse);
        expect(pending.isAccessLocked, isTrue);
        expect(await pending.resumeAfterFailedSave('old-password'), isTrue);
        final recovered = (await pending.getPasswordsByCategory('General'))
            .single;
        expect(
          await pending.decryptPassword(recovered['password'] as String),
          'unsaved-secret',
        );
        expect(pending.needsSave, isTrue);
        expect(await pending.attemptEncrypt(), isFalse);
        expect(await file.readAsBytes(), committed);
      } finally {
        await pending.dispose();
        await newer.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'pending changes can be saved after a storage failure is repaired',
    () async {
      final dir = await Directory.systemTemp.createTemp('kt-retry-');
      final file = File('${dir.path}/vault.ktn');
      final vault = passFile(file.path, 'master');
      final reopened = passFile(file.path, 'master');
      try {
        await vault.newSQLFile();
        await vault.savePassword(_entry('original'));
        expect(await vault.attemptEncrypt(), isTrue);
        final row = (await vault.getPasswordsByCategory('General')).single;
        await vault.savePassword(_entry('pending', id: row['id'] as int));
        final backup = await file.rename('${dir.path}/original');
        await Directory(file.path).create();
        vault.lockAccess();
        expect(await vault.attemptEncrypt(), isFalse);
        expect(await vault.suspendForRecovery(), isTrue);
        expect(await vault.resumeAfterFailedSave('master'), isTrue);
        await Directory(file.path).delete();
        await backup.rename(file.path);
        expect(await vault.attemptEncrypt(), isTrue);
        expect(await reopened.attemptDecrypt(), isTrue);
        final recovered = (await reopened.getPasswordsByCategory('General'))
            .single;
        expect(
          await reopened.decryptPassword(recovered['password'] as String),
          'pending',
        );
      } finally {
        await vault.dispose();
        await reopened.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'error-marker text is a valid password across saving and rekeying',
    () async {
      final dir = await Directory.systemTemp.createTemp('kt-marker-');
      final vault = passFile('${dir.path}/vault.ktn', 'master');
      try {
        await vault.newSQLFile();
        await vault.savePassword(_entry('[Decryption Error]'));
        expect(await vault.attemptEncrypt(), isTrue);
        final original = (await vault.getPasswordsByCategory('General')).single;
        expect(
          await vault.decryptPassword(original['password'] as String),
          '[Decryption Error]',
        );
        expect(
          await vault.changeMasterPassword(
            currentPassword: 'master',
            newPassword: 'replacement',
          ),
          isTrue,
        );
        final rekeyed = (await vault.getPasswordsByCategory('General')).single;
        expect(
          await vault.decryptPassword(rekeyed['password'] as String),
          '[Decryption Error]',
        );
        await expectLater(
          vault.decryptPassword('c20p2:broken:broken'),
          throwsA(isA<PasswordDecryptionException>()),
        );
      } finally {
        await vault.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test('new files and replacement files retain private POSIX modes', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('kt-modes-');
    final target = File('${dir.path}/vault.ktn');
    try {
      await VaultFileCommit.writeBytes(
        target,
        Uint8List.fromList([1]),
        expectedFingerprint: null,
      );
      expect((await target.stat()).mode & 0x1ff, 0x180);
      final expected = await VaultFileCommit.fingerprint(target);
      expect((await Process.run('chmod', ['400', target.path])).exitCode, 0);
      await VaultFileCommit.writeBytes(
        target,
        Uint8List.fromList([2]),
        expectedFingerprint: expected,
      );
      expect((await target.stat()).mode & 0x1ff, 0x100);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('two OS processes cannot both commit the same vault revision', () async {
    final dir = await Directory.systemTemp.createTemp('kt-processes-');
    final file = File('${dir.path}/vault.ktn');
    final processes = <Process>[];
    try {
      await file.writeAsString('original');
      final expected = (await VaultFileCommit.fingerprint(file))!;
      final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
      final dart =
          '$flutterRoot/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
      final lines = <StreamIterator<String>>[];
      final errors = <Future<String>>[];
      for (final text in ['first', 'second']) {
        final process = await Process.start(dart, [
          '--packages=.dart_tool/package_config.json',
          'test/support/vault_commit_worker.dart',
          file.path,
          expected,
          text,
        ]);
        processes.add(process);
        errors.add(process.stderr.transform(utf8.decoder).join());
        final output = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        lines.add(output);
        expect(await output.moveNext(), isTrue);
        expect(output.current, 'ready');
      }
      for (final process in processes) {
        process.stdin.writeln('go');
        await process.stdin.close();
      }
      final outcomes = <String>[];
      for (var i = 0; i < processes.length; i++) {
        expect(await lines[i].moveNext(), isTrue);
        outcomes.add(lines[i].current);
        expect(await processes[i].exitCode, 0, reason: await errors[i]);
        await lines[i].cancel();
      }
      expect(outcomes, unorderedEquals(['saved', 'conflict']));
      expect(await file.readAsString(), anyOf('first', 'second'));
    } finally {
      for (final process in processes) {
        process.kill();
      }
      await dir.delete(recursive: true);
    }
  });

  test('download cannot overwrite a local edit made during transfer', () async {
    final dir = await Directory.systemTemp.createTemp('kt-download-race-');
    final file = File('${dir.path}/vault.ktn');
    final started = Completer<void>(), finish = Completer<void>();
    Stream<List<int>> source() async* {
      started.complete();
      await finish.future;
      yield [...utf8.encode('KTN3'), ...List<int>.filled(45, 7)];
    }

    try {
      await file.writeAsString('original');
      final download = writeVaultDownloadAtomically(
        source: source(),
        destinationPath: file.path,
        replaceExisting: true,
      );
      final rejected = expectLater(download, throwsA(isA<VaultFileConflict>()));
      await started.future;
      await VaultFileCommit.writeBytes(
        file,
        Uint8List.fromList(utf8.encode('newer')),
        expectedFingerprint: await VaultFileCommit.fingerprint(file),
      );
      finish.complete();
      await rejected;
      expect(await file.readAsString(), 'newer');
      expect(await dir.list().length, 2); // Vault and persistent lock only.
    } finally {
      if (!finish.isCompleted) finish.complete();
      await dir.delete(recursive: true);
    }
  });

  test('vault and lock symlinks cannot redirect a commit', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('kt-symlink-');
    final victim = File('${dir.path}/other')..writeAsStringSync('untouched');
    final vault = File('${dir.path}/vault.ktn');
    try {
      final link = await Link(vault.path).create(victim.path);
      await expectLater(
        VaultFileCommit.writeBytes(
          vault,
          Uint8List.fromList([9]),
          expectedFingerprint: null,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await victim.readAsString(), 'untouched');
      await link.delete();
      await File('${dir.path}/.vault.ktn.lock').delete();
      await Link('${dir.path}/.vault.ktn.lock').create(victim.path);
      await expectLater(
        VaultFileCommit.writeBytes(
          vault,
          Uint8List.fromList([9]),
          expectedFingerprint: null,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await victim.readAsString(), 'untouched');
      expect(await vault.exists(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
