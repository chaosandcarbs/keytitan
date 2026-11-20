import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:cryptography/dart.dart' show DartArgon2id;
import 'sensitive.dart';
import 'secure_kdf.dart';

enum KeyTitanVaultVersion { unknown, v3, v4 }

class Ktn4KeyEnvelope {
  const Ktn4KeyEnvelope({
    required this.vaultId,
    required this.salt,
    required this.wrapNonce,
    required this.wrappedVaultKey,
  });

  final Uint8List vaultId;
  final Uint8List salt;
  final Uint8List wrapNonce;
  final Uint8List wrappedVaultKey;
}

class Ktn4DecodedVault {
  const Ktn4DecodedVault({
    required this.sqliteBytes,
    required this.vaultKey,
    required this.envelope,
    required this.revision,
  });

  final Uint8List sqliteBytes;
  final Uint8List vaultKey;
  final Ktn4KeyEnvelope envelope;
  final int revision;
}

class Ktn4EncodedVault {
  const Ktn4EncodedVault({required this.bytes, required this.revision});

  final Uint8List bytes;
  final int revision;
}

class KeyTitanVaultCodec {
  KeyTitanVaultCodec._();

  static const List<int> v3Magic = [0x4b, 0x54, 0x4e, 0x33]; // KTN3
  static const List<int> v4Magic = [0x4b, 0x54, 0x4e, 0x34]; // KTN4

  static const int argonMemoryKiB = 65536;
  static const int argonIterations = 3;
  static const int argonParallelism = 2;
  static const int keyLength = 32;
  static const int saltLength = 16;
  static const int nonceLength = 12;
  static const int vaultIdLength = 16;
  static const int aeadTagLength = 16;

  // KTN4 byte layout (all integers are unsigned, big-endian):
  //   0..4     magic "KTN4"
  //   4..8     header length (132)
  //   8..12    Argon2 memory in KiB
  //   12..16   Argon2 iterations
  //   16..20   Argon2 parallelism
  //   20..36   random vault ID
  //   36..52   Argon2 salt
  //   52..64   vault-key wrapping nonce
  //   64..112  wrapped 32-byte vault key plus 16-byte tag
  //   112..120 payload revision
  //   120..132 payload nonce
  //   132..    encrypted SQLite bytes plus 16-byte tag
  static const int v4HeaderLength = 132;
  static const int maxRevision = 0x7fffffffffffffff;
  static const int _wrapAadLength = 64;
  static const int _wrappedKeyLength = keyLength + aeadTagLength;
  static const int v3MinimumLength = 49;
  static const int v4MinimumLength =
      v4HeaderLength + 16 + aeadTagLength; // SQLite header + AEAD tag.

  static final crypto.Cipher _cipher = crypto.Chacha20.poly1305Aead();

  static KeyTitanVaultVersion detectVersion(List<int> bytes) {
    if (_startsWith(bytes, v4Magic)) return KeyTitanVaultVersion.v4;
    if (_startsWith(bytes, v3Magic)) return KeyTitanVaultVersion.v3;
    return KeyTitanVaultVersion.unknown;
  }

  static bool hasSupportedEnvelope(List<int> bytes) {
    return hasSupportedEnvelopeHeader(bytes, bytes.length);
  }

  static bool hasSupportedEnvelopeHeader(List<int> header, int totalLength) {
    switch (detectVersion(header)) {
      case KeyTitanVaultVersion.v3:
        return totalLength >= v3MinimumLength;
      case KeyTitanVaultVersion.v4:
        if (header.length < v4HeaderLength || totalLength < v4MinimumLength) {
          return false;
        }
        final input = Uint8List.fromList(header.sublist(0, v4HeaderLength));
        final view = ByteData.sublistView(input);
        final revision = view.getUint64(112, Endian.big);
        return view.getUint32(4, Endian.big) == v4HeaderLength &&
            view.getUint32(8, Endian.big) == argonMemoryKiB &&
            view.getUint32(12, Endian.big) == argonIterations &&
            view.getUint32(16, Endian.big) == argonParallelism &&
            revision > 0 &&
            revision <= maxRevision;
      case KeyTitanVaultVersion.unknown:
        return false;
    }
  }

  static Future<Uint8List?> decryptV3(
    Uint8List input,
    Uint8List passwordBytes,
  ) async {
    if (input.length < v3MinimumLength ||
        detectVersion(input) != KeyTitanVaultVersion.v3) {
      return null;
    }

    final nonce = input.sublist(4, 16);
    final salt = Uint8List.fromList(input.sublist(16, 32));
    final payload = input.sublist(32);
    final key = await _deriveArgon2idKey(passwordBytes, salt);
    try {
      final plaintext = await _decrypt(key, nonce, payload);
      if (plaintext == null || !_isSqliteBytes(plaintext)) {
        plaintext?.fillRange(0, plaintext.length, 0);
        return null;
      }
      return plaintext;
    } finally {
      key.fillRange(0, key.length, 0);
      salt.fillRange(0, salt.length, 0);
    }
  }

  static Future<Ktn4DecodedVault?> decryptV4(
    Uint8List input,
    Uint8List passwordBytes,
  ) async {
    if (!_isStructurallyValidV4(input)) return null;

    final view = ByteData.sublistView(input);
    final revision = view.getUint64(112, Endian.big);
    final envelope = Ktn4KeyEnvelope(
      vaultId: Uint8List.fromList(input.sublist(20, 36)),
      salt: Uint8List.fromList(input.sublist(36, 52)),
      wrapNonce: Uint8List.fromList(input.sublist(52, 64)),
      wrappedVaultKey: Uint8List.fromList(input.sublist(64, 112)),
    );

    final kek = await _deriveArgon2idKey(passwordBytes, envelope.salt);
    Uint8List? vaultKey;
    try {
      vaultKey = await _decrypt(
        kek,
        envelope.wrapNonce,
        envelope.wrappedVaultKey,
        aad: input.sublist(0, _wrapAadLength),
      );
    } finally {
      kek.fillRange(0, kek.length, 0);
    }

    if (vaultKey == null || vaultKey.length != keyLength) {
      vaultKey?.fillRange(0, vaultKey.length, 0);
      return null;
    }

    final payloadNonce = input.sublist(120, v4HeaderLength);
    final payload = input.sublist(v4HeaderLength);
    final sqliteBytes = await _decrypt(
      vaultKey,
      payloadNonce,
      payload,
      aad: input.sublist(0, v4HeaderLength),
    );
    if (sqliteBytes == null || !_isSqliteBytes(sqliteBytes)) {
      sqliteBytes?.fillRange(0, sqliteBytes.length, 0);
      vaultKey.fillRange(0, vaultKey.length, 0);
      return null;
    }

    return Ktn4DecodedVault(
      sqliteBytes: sqliteBytes,
      vaultKey: vaultKey,
      envelope: envelope,
      revision: revision,
    );
  }

  static Future<Ktn4KeyEnvelope> createEnvelope(
    Uint8List passwordBytes,
    Uint8List vaultKey, {
    Uint8List? vaultId,
  }) async {
    if (vaultKey.length != keyLength) {
      throw ArgumentError.value(
        vaultKey.length,
        'vaultKey',
        'Must be 32 bytes',
      );
    }
    if (vaultId != null && vaultId.length != vaultIdLength) {
      throw ArgumentError.value(vaultId.length, 'vaultId', 'Must be 16 bytes');
    }

    final actualVaultId = Uint8List.fromList(
      vaultId ?? _secureRandomBytes(vaultIdLength),
    );
    final salt = _secureRandomBytes(saltLength);
    final wrapNonce = _secureRandomBytes(nonceLength);
    final aad = _buildWrapAad(actualVaultId, salt, wrapNonce);
    final kek = await _deriveArgon2idKey(passwordBytes, salt);
    try {
      final wrappedKey = await _encrypt(kek, wrapNonce, vaultKey, aad: aad);
      if (wrappedKey.length != _wrappedKeyLength) {
        wrappedKey.fillRange(0, wrappedKey.length, 0);
        throw StateError('Unexpected wrapped vault-key length.');
      }
      return Ktn4KeyEnvelope(
        vaultId: actualVaultId,
        salt: salt,
        wrapNonce: wrapNonce,
        wrappedVaultKey: wrappedKey,
      );
    } finally {
      kek.fillRange(0, kek.length, 0);
      aad.fillRange(0, aad.length, 0);
    }
  }

  static Future<bool> passwordUnlocksEnvelope(
    Uint8List passwordBytes,
    Uint8List expectedVaultKey,
    Ktn4KeyEnvelope envelope,
  ) async {
    if (expectedVaultKey.length != keyLength) return false;

    final aad = _buildWrapAad(
      envelope.vaultId,
      envelope.salt,
      envelope.wrapNonce,
    );
    final kek = await _deriveArgon2idKey(passwordBytes, envelope.salt);
    Uint8List? candidate;
    try {
      candidate = await _decrypt(
        kek,
        envelope.wrapNonce,
        envelope.wrappedVaultKey,
        aad: aad,
      );
      return candidate != null &&
          _constantTimeEquals(candidate, expectedVaultKey);
    } finally {
      candidate?.fillRange(0, candidate.length, 0);
      kek.fillRange(0, kek.length, 0);
      aad.fillRange(0, aad.length, 0);
    }
  }

  static Future<Ktn4EncodedVault> encryptV4(
    Uint8List sqliteBytes,
    Uint8List vaultKey,
    Ktn4KeyEnvelope envelope,
    int previousRevision,
  ) async {
    if (!_isSqliteBytes(sqliteBytes)) {
      throw const FormatException('Vault payload is not a SQLite database.');
    }
    if (vaultKey.length != keyLength) {
      throw ArgumentError.value(
        vaultKey.length,
        'vaultKey',
        'Must be 32 bytes',
      );
    }
    if (previousRevision < 0 || previousRevision >= maxRevision) {
      throw StateError('The vault revision cannot be incremented.');
    }

    final revision = previousRevision + 1;
    final payloadNonce = _secureRandomBytes(nonceLength);
    final header = _buildHeader(envelope, revision, payloadNonce);
    final encryptedPayload = await _encrypt(
      vaultKey,
      payloadNonce,
      sqliteBytes,
      aad: header,
    );
    final output = Uint8List(header.length + encryptedPayload.length)
      ..setRange(0, header.length, header)
      ..setRange(
        header.length,
        header.length + encryptedPayload.length,
        encryptedPayload,
      );
    return Ktn4EncodedVault(bytes: output, revision: revision);
  }

  static bool _isStructurallyValidV4(Uint8List input) {
    if (input.length < v4MinimumLength ||
        detectVersion(input) != KeyTitanVaultVersion.v4) {
      return false;
    }
    final view = ByteData.sublistView(input);
    final revision = view.getUint64(112, Endian.big);
    return view.getUint32(4, Endian.big) == v4HeaderLength &&
        view.getUint32(8, Endian.big) == argonMemoryKiB &&
        view.getUint32(12, Endian.big) == argonIterations &&
        view.getUint32(16, Endian.big) == argonParallelism &&
        revision > 0 &&
        revision <= maxRevision;
  }

  static Uint8List _buildWrapAad(
    Uint8List vaultId,
    Uint8List salt,
    Uint8List wrapNonce,
  ) {
    if (vaultId.length != vaultIdLength ||
        salt.length != saltLength ||
        wrapNonce.length != nonceLength) {
      throw ArgumentError('Invalid KTN4 key-envelope component length.');
    }
    final aad = Uint8List(_wrapAadLength);
    aad.setRange(0, 4, v4Magic);
    final view = ByteData.sublistView(aad);
    view.setUint32(4, v4HeaderLength, Endian.big);
    view.setUint32(8, argonMemoryKiB, Endian.big);
    view.setUint32(12, argonIterations, Endian.big);
    view.setUint32(16, argonParallelism, Endian.big);
    aad.setRange(20, 36, vaultId);
    aad.setRange(36, 52, salt);
    aad.setRange(52, 64, wrapNonce);
    return aad;
  }

  static Uint8List _buildHeader(
    Ktn4KeyEnvelope envelope,
    int revision,
    Uint8List payloadNonce,
  ) {
    if (envelope.wrappedVaultKey.length != _wrappedKeyLength ||
        payloadNonce.length != nonceLength) {
      throw ArgumentError('Invalid KTN4 header component length.');
    }
    final wrapAad = _buildWrapAad(
      envelope.vaultId,
      envelope.salt,
      envelope.wrapNonce,
    );
    final header = Uint8List(v4HeaderLength);
    header.setRange(0, _wrapAadLength, wrapAad);
    header.setRange(64, 112, envelope.wrappedVaultKey);
    ByteData.sublistView(header).setUint64(112, revision, Endian.big);
    header.setRange(120, v4HeaderLength, payloadNonce);
    wrapAad.fillRange(0, wrapAad.length, 0);
    return header;
  }

  static Future<Uint8List> _deriveArgon2idKey(
    Uint8List passwordBytes,
    Uint8List salt,
  ) async {
    // The public byte-oriented state avoids a password -> String -> bytes
    // roundtrip and the non-overwriting SecretKey returned by deriveKey().
    final state = DartArgon2id(
      memory: argonMemoryKiB,
      parallelism: argonParallelism,
      iterations: argonIterations,
      hashLength: keyLength,
    ).newState();
    return deriveAndClearArgon2id(state, password: passwordBytes, salt: salt);
  }

  static Future<Uint8List> _encrypt(
    Uint8List keyBytes,
    List<int> nonce,
    List<int> plaintext, {
    List<int> aad = const <int>[],
  }) async {
    final secretKey = await _cipher.newSecretKeyFromBytes(keyBytes);
    try {
      final secretBox = await _cipher.encrypt(
        plaintext,
        secretKey: secretKey,
        nonce: nonce,
        aad: aad,
      );
      return Uint8List.fromList(secretBox.cipherText + secretBox.mac.bytes);
    } finally {
      secretKey.destroy();
    }
  }

  static Future<Uint8List?> _decrypt(
    Uint8List keyBytes,
    List<int> nonce,
    List<int> encrypted, {
    List<int> aad = const <int>[],
  }) async {
    if (nonce.length != nonceLength || encrypted.length < aeadTagLength) {
      return null;
    }
    final secretBox = crypto.SecretBox(
      encrypted.sublist(0, encrypted.length - aeadTagLength),
      nonce: nonce,
      mac: crypto.Mac(encrypted.sublist(encrypted.length - aeadTagLength)),
    );
    final secretKey = await _cipher.newSecretKeyFromBytes(keyBytes);
    List<int>? plaintext;
    try {
      plaintext = await _cipher.decrypt(
        secretBox,
        secretKey: secretKey,
        aad: aad,
      );
      return Uint8List.fromList(plaintext);
    } on crypto.SecretBoxAuthenticationError {
      return null;
    } finally {
      wipeBytes(plaintext);
      secretKey.destroy();
    }
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _isSqliteBytes(List<int> bytes) {
    const header = <int>[
      0x53,
      0x51,
      0x4c,
      0x69,
      0x74,
      0x65,
      0x20,
      0x66,
      0x6f,
      0x72,
      0x6d,
      0x61,
      0x74,
      0x20,
      0x33,
      0x00,
    ];
    return _startsWith(bytes, header);
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    var diff = left.length ^ right.length;
    final maxLength = max(left.length, right.length);
    for (var i = 0; i < maxLength; i++) {
      diff |=
          (i < left.length ? left[i] : 0) ^ (i < right.length ? right[i] : 0);
    }
    return diff == 0;
  }

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
