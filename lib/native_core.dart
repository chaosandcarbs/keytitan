import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

class KeyTitanNativeCore {
  KeyTitanNativeCore._(this._lib) {
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('ktn_free');
    _decryptVault =
        _lib.lookupFunction<_Bytes2Native, _Bytes2Dart>('ktn_decrypt_vault');
    _encryptVault =
        _lib.lookupFunction<_Bytes2Native, _Bytes2Dart>('ktn_encrypt_vault');
    _fieldEncrypt =
        _lib.lookupFunction<_Bytes2Native, _Bytes2Dart>('ktn_field_encrypt');
    _fieldDecrypt =
        _lib.lookupFunction<_Bytes2Native, _Bytes2Dart>('ktn_field_decrypt');
    _deriveUris =
        _lib.lookupFunction<_Bytes1Native, _Bytes1Dart>('ktn_derive_uris');
  }

  static KeyTitanNativeCore? _instance;
  static bool _loadAttempted = false;
  static const bool _isProduct = bool.fromEnvironment('dart.vm.product');

  final DynamicLibrary _lib;
  late final _FreeDart _free;
  late final _Bytes2Dart _decryptVault;
  late final _Bytes2Dart _encryptVault;
  late final _Bytes2Dart _fieldEncrypt;
  late final _Bytes2Dart _fieldDecrypt;
  late final _Bytes1Dart _deriveUris;

  static KeyTitanNativeCore? get instance {
    if (_loadAttempted) return _instance;
    _loadAttempted = true;
    try {
      _instance = KeyTitanNativeCore._(_openLibrary());
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }

  static bool get isAvailable => instance != null;

  Uint8List? decryptVault(Uint8List encryptedVault, Uint8List passwordBytes) {
    return _callBytes2(_decryptVault, encryptedVault, passwordBytes);
  }

  Uint8List? encryptVault(Uint8List sqliteBytes, Uint8List passwordBytes) {
    return _callBytes2(_encryptVault, sqliteBytes, passwordBytes);
  }

  String? fieldEncrypt(Uint8List passwordBytes, String plaintext) {
    final result =
        _callBytes2(_fieldEncrypt, passwordBytes, utf8.encode(plaintext));
    if (result == null) return null;
    return utf8.decode(result);
  }

  String? fieldDecrypt(Uint8List passwordBytes, String ciphertext) {
    final result =
        _callBytes2(_fieldDecrypt, passwordBytes, utf8.encode(ciphertext));
    if (result == null) return null;
    return utf8.decode(result);
  }

  String? deriveUris(String site) {
    final result = _callBytes1(_deriveUris, utf8.encode(site));
    if (result == null) return null;
    return utf8.decode(result);
  }

  Uint8List? _callBytes1(_Bytes1Dart fn, List<int> input) {
    final inputPtr = _allocBytes(input);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      final status = fn(inputPtr, input.length, outPtr, outLen);
      return _readNativeOutput(status, outPtr.value, outLen.value);
    } finally {
      _zeroFree(inputPtr, input.length);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  Uint8List? _callBytes2(
    _Bytes2Dart fn,
    List<int> input,
    List<int> passwordBytes,
  ) {
    final inputPtr = _allocBytes(input);
    final passwordPtr = _allocBytes(passwordBytes);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      final status = fn(
        inputPtr,
        input.length,
        passwordPtr,
        passwordBytes.length,
        outPtr,
        outLen,
      );
      return _readNativeOutput(status, outPtr.value, outLen.value);
    } finally {
      _zeroFree(inputPtr, input.length);
      _zeroFree(passwordPtr, passwordBytes.length);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  Uint8List? _readNativeOutput(
    int status,
    Pointer<Uint8> outPtr,
    int outLen,
  ) {
    if (status != 0) return null;
    if (outLen == 0) return Uint8List(0);
    if (outPtr == nullptr) return null;

    try {
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } finally {
      _free(outPtr, outLen);
    }
  }

  static Pointer<Uint8> _allocBytes(List<int> bytes) {
    if (bytes.isEmpty) return nullptr;
    final ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }

  // Wipe Dart-owned FFI buffers before returning them to calloc.
  static void _zeroFree(Pointer<Uint8> ptr, int len) {
    if (ptr == nullptr) return;
    if (len > 0) ptr.asTypedList(len).fillRange(0, len, 0);
    calloc.free(ptr);
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libkeytitan_core.so');
    }
    if (Platform.isLinux) {
      return _openFirst([
        ..._bundledLibraryCandidates('libkeytitan_core.so',
            linuxUsesLibDirectory: true),
        if (!_isProduct) ...[
          'native/keytitan_core/target/release/libkeytitan_core.so',
          'native/keytitan_core/target/debug/libkeytitan_core.so',
        ],
      ]);
    }
    if (Platform.isWindows) {
      return _openFirst([
        ..._bundledLibraryCandidates('keytitan_core.dll'),
        if (!_isProduct) ...[
          'native/keytitan_core/target/release/keytitan_core.dll',
          'native/keytitan_core/target/debug/keytitan_core.dll',
        ],
      ]);
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError('Unsupported platform');
  }

  static List<String> _bundledLibraryCandidates(
    String fileName, {
    bool linuxUsesLibDirectory = false,
  }) {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    return [
      if (linuxUsesLibDirectory) p.join(executableDir, 'lib', fileName),
      p.join(executableDir, fileName),
    ];
  }

  static DynamicLibrary _openFirst(List<String> candidates) {
    Object? lastError;
    for (final candidate in candidates) {
      try {
        if (candidate.contains('/') || candidate.contains('\\')) {
          final file = File(candidate);
          if (!file.existsSync()) continue;
          return DynamicLibrary.open(file.absolute.path);
        }
        return DynamicLibrary.open(candidate);
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('Could not load keytitan_core: $lastError');
  }
}

typedef _Bytes2Native = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);

typedef _Bytes2Dart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);

typedef _Bytes1Native = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);

typedef _Bytes1Dart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Size>,
);

typedef _FreeNative = Void Function(Pointer<Uint8>, Size);
typedef _FreeDart = void Function(Pointer<Uint8>, int);
