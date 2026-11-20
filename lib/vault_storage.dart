import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

class VaultFileConflict implements Exception {
  const VaultFileConflict();

  @override
  String toString() =>
      'The vault changed in another session. Reopen it before saving.';
}

/// A private, unpredictable sibling directory keeps uncommitted vaults out of
/// reach of other users, including while their final permissions are applied.
class VaultStagingFile {
  VaultStagingFile._(this.directory, this.file);

  final Directory directory;
  final File file;
  bool _retainForRecovery = false;

  static Future<VaultStagingFile> create(File target) async {
    final directory = await target.parent.createTemp('.keytitan-');
    try {
      _FileSecurity.private(directory.path, directory: true);
      final file = await File(
        p.join(directory.path, 'vault.tmp'),
      ).create(exclusive: true);
      _FileSecurity.private(file.path);
      return VaultStagingFile._(directory, file);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_retainForRecovery) return;
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Cleanup must not turn a completed commit into a reported save failure.
    }
  }
}

/// All desktop writers use the same stable sidecar lock, which is never
/// unlinked: deleting it could let two processes lock different inodes.
/// POSIX flock is handle-based, unlike Dart's process-scoped POSIX File.lock.
class VaultFileCommit {
  static Future<String?> fingerprint(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Vault must be a regular file', file.path);
    }
    return (await sha256.bind(file.openRead()).first).toString().toUpperCase();
  }

  static Future<void> writeBytes(
    File target,
    Uint8List bytes, {
    required String? expectedFingerprint,
  }) async {
    await target.parent.create(recursive: true);
    final staging = await VaultStagingFile.create(target);
    try {
      await staging.file.writeAsBytes(bytes, flush: true);
      await commit(staging, target, expectedFingerprint: expectedFingerprint);
    } finally {
      await staging.dispose();
    }
  }

  static Future<void> commit(
    VaultStagingFile staging,
    File destination, {
    required String? expectedFingerprint,
  }) async {
    final parent = await destination.parent.resolveSymbolicLinks();
    final target = File(p.join(parent, p.basename(destination.path)));
    final lock = await _CommitLock.acquire(
      File(p.join(parent, '.${p.basename(target.path)}.lock')),
    );
    try {
      if (await fingerprint(target) != expectedFingerprint) {
        throw const VaultFileConflict();
      }
      final exists = expectedFingerprint != null;
      final previousMode = exists ? (await target.stat()).mode : 0x180;
      final handle = await staging.file.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      if (Platform.isWindows) {
        if (exists) {
          // ReplaceFile preserves the existing DACL. Do not ignore ACL errors.
          final backup = File(p.join(staging.directory.path, 'previous.bak'));
          try {
            _WindowsFiles.replace(target.path, staging.file.path, backup.path);
          } catch (_) {
            if (!await target.exists() && await backup.exists()) {
              try {
                await backup.rename(target.path);
              } catch (_) {
                staging._retainForRecovery = true;
                throw FileSystemException(
                  'Previous vault retained for recovery',
                  backup.path,
                );
              }
            }
            rethrow;
          }
        } else {
          // No REPLACE_EXISTING flag: a newly appearing file is a conflict.
          _WindowsFiles.moveNew(staging.file.path, target.path);
        }
      } else {
        // Never grant group/other access, or add owner permissions the old
        // vault did not have. On Linux this disables inherited ACL grants too.
        _PosixFiles.chmod(staging.file.path, previousMode & 0x180);
        if (exists) {
          await staging.file.rename(target.path);
        } else {
          // link() atomically claims an absent destination without truncating
          // or replacing any file/link/directory that appeared meanwhile.
          _PosixFiles.linkNew(staging.file.path, target.path);
        }
      }
    } finally {
      await lock.release();
    }
  }
}

abstract class _CommitLock {
  static Future<_CommitLock> acquire(File file) async {
    final lock = Platform.isWindows
        ? await _WindowsLock.open(file)
        : _PosixLock.open(file);
    final timer = Stopwatch()..start();
    try {
      while (!await lock.tryLock()) {
        if (timer.elapsed >= const Duration(seconds: 5)) {
          throw FileSystemException(
            'Another process is saving this vault. Retry shortly.',
            file.path,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return lock;
    } catch (_) {
      await lock.release();
      rethrow;
    }
  }

  Future<bool> tryLock();
  Future<void> release();
}

class _PosixLock extends _CommitLock {
  _PosixLock(this.fd);
  final int fd;

  static _PosixLock open(File file) =>
      _PosixLock(_PosixFiles.openLock(file.path));

  @override
  Future<bool> tryLock() async {
    if (_PosixFiles.flock(fd, 2 | 4) == 0) return true; // LOCK_EX | LOCK_NB
    final error = _PosixFiles.errno();
    if (error == 4 ||
        error == ((Platform.isLinux || Platform.isAndroid) ? 11 : 35)) {
      return false;
    }
    throw FileSystemException(
      'Could not lock vault',
      '',
      OSError('flock failed', error),
    );
  }

  @override
  Future<void> release() async {
    _PosixFiles.close(fd);
  }
}

class _WindowsLock extends _CommitLock {
  _WindowsLock(this.handle);
  final RandomAccessFile handle;
  bool locked = false;

  static Future<_WindowsLock> open(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException('Invalid vault lock file', file.path);
    }
    if (type == FileSystemEntityType.notFound) {
      try {
        await file.create(exclusive: true);
      } on PathExistsException {
        /* Another writer created it. */
      }
    }
    _FileSecurity.private(file.path);
    return _WindowsLock(await file.open(mode: FileMode.append));
  }

  @override
  Future<bool> tryLock() async {
    try {
      await handle.lock(FileLock.exclusive, 0, 1);
      return locked = true;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 33) return false; // ERROR_LOCK_VIOLATION
      rethrow;
    }
  }

  @override
  Future<void> release() async {
    try {
      if (locked) await handle.unlock(0, 1);
    } finally {
      await handle.close();
    }
  }
}

class _FileSecurity {
  static void private(String path, {bool directory = false}) {
    if (Platform.isWindows) {
      _WindowsFiles.makePrivate(path, directory: directory);
    } else {
      _PosixFiles.chmod(path, directory ? 0x1c0 : 0x180); // 0700 / 0600
    }
  }
}

class _PosixFiles {
  static final _lib = DynamicLibrary.process();
  static final _linux = Platform.isLinux || Platform.isAndroid;
  static final _open = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final flock = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _chmod = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  static final _fchmod = _lib
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'fchmod',
      );
  static final _link = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('link');
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isAndroid
            ? '__errno'
            : (_linux ? '__errno_location' : '__error'),
      );
  static int errno() => _errno().value;

  static int openLock(String path) {
    final name = path.toNativeUtf8();
    try {
      // O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, with private creation mode.
      final flags =
          2 | (_linux ? 0x40 | 0x20000 | 0x80000 : 0x200 | 0x100 | 0x1000000);
      final fd = _open(name, flags, 0x180);
      if (fd < 0) {
        throw FileSystemException(
          'Could not open vault lock',
          path,
          OSError('open failed', errno()),
        );
      }
      if (_fchmod(fd, 0x180) != 0) {
        final error = errno();
        close(fd);
        throw FileSystemException(
          'Could not protect vault lock',
          path,
          OSError('fchmod failed', error),
        );
      }
      return fd;
    } finally {
      calloc.free(name);
    }
  }

  static void chmod(String path, int mode) {
    final name = path.toNativeUtf8();
    try {
      if (_chmod(name, mode) != 0) {
        throw FileSystemException(
          'Could not protect vault file',
          path,
          OSError('chmod failed', errno()),
        );
      }
    } finally {
      calloc.free(name);
    }
  }

  static void linkNew(String source, String target) {
    final from = source.toNativeUtf8(), to = target.toNativeUtf8();
    try {
      if (_link(from, to) != 0) {
        throw FileSystemException(
          'Could not create vault without overwriting',
          target,
          OSError('link failed', errno()),
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}

class _WindowsFiles {
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _advapi = DynamicLibrary.open('advapi32.dll');
  static final _replace = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('ReplaceFileW');
  static final _move = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('MoveFileExW');
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _convertDescriptor = _advapi
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  static final _setSecurity = _advapi
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Pointer<Void>),
        int Function(Pointer<Utf16>, int, Pointer<Void>)
      >('SetFileSecurityW');
  static final _localFree = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  static void makePrivate(String path, {required bool directory}) {
    final name = path.toNativeUtf16();
    final inheritance = directory ? 'OICI' : '';
    // OW is the object's owner; SY is Local System. Protect against inherited
    // access from a shared parent. Existing vault DACLs survive ReplaceFile.
    final sddl = 'D:P(A;$inheritance;FA;;;OW)(A;$inheritance;FA;;;SY)'
        .toNativeUtf16();
    final descriptor = calloc<Pointer<Void>>();
    try {
      if (_convertDescriptor(sddl, 1, descriptor, nullptr) == 0 ||
          _setSecurity(name, 0x80000004, descriptor.value) == 0) {
        throw FileSystemException(
          'Could not protect vault file',
          path,
          OSError('SetFileSecurity failed', _lastError()),
        );
      }
    } finally {
      if (descriptor.value != nullptr) _localFree(descriptor.value);
      calloc.free(descriptor);
      calloc.free(sddl);
      calloc.free(name);
    }
  }

  static void replace(String target, String source, String backup) {
    final to = target.toNativeUtf16(),
        from = source.toNativeUtf16(),
        previous = backup.toNativeUtf16();
    try {
      if (_replace(to, from, previous, 0, nullptr, nullptr) == 0) {
        throw FileSystemException(
          'Could not replace vault',
          target,
          OSError('ReplaceFile failed', _lastError()),
        );
      }
    } finally {
      calloc.free(to);
      calloc.free(from);
      calloc.free(previous);
    }
  }

  static void moveNew(String source, String target) {
    final from = source.toNativeUtf16(), to = target.toNativeUtf16();
    try {
      if (_move(from, to, 8) == 0) {
        throw FileSystemException(
          'Could not create vault without overwriting',
          target,
          OSError('MoveFileEx failed', _lastError()),
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}
