import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart' show SecretKeyData;
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/secure_kdf.dart';

class _FailingState implements DartArgon2State {
  final workspace = Uint8List(1024);
  bool released = false;

  @override
  Uint32List getBlock({
    required int lane,
    required int slice,
    required int index,
  }) => workspace.buffer.asUint32List();

  @override
  Future<List<int>> deriveKeyBytes({
    required List<int> password,
    List<int> nonce = const [],
    List<int> optionalSecret = const [],
    List<int> associatedData = const [],
  }) async {
    workspace.fillRange(0, workspace.length, 0x42);
    throw StateError('Synthetic KDF failure');
  }

  @override
  void tryReleaseMemory() {
    expect(workspace.every((b) => b == 0), isTrue);
    released = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Argon2 workspace is wiped while its returned key remains usable',
    () async {
      final workspace = Uint8List(64 * 1024);
      final state = DartArgon2State(
        mode: DartArgon2Mode.argon2id,
        memory: 64,
        parallelism: 2,
        iterations: 3,
        hashLength: 32,
        buffer: workspace.buffer,
      );
      final password = Uint8List.fromList([1, 2, 3]);
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final expected = await DartArgon2id(
        memory: 64,
        parallelism: 2,
        iterations: 3,
        hashLength: 32,
      ).deriveKey(secretKey: SecretKeyData(password), nonce: salt);
      final actual = await deriveAndClearArgon2id(
        state,
        password: password,
        salt: salt,
      );
      expect(actual, await expected.extractBytes());
      expect(workspace.every((b) => b == 0), isTrue);
      actual.fillRange(0, actual.length, 0);
      expected.destroy();
    },
  );

  test('Argon2 failure wipes workspace before release', () async {
    final state = _FailingState();
    await expectLater(
      deriveAndClearArgon2id(
        state,
        password: Uint8List.fromList([1]),
        salt: Uint8List(16),
      ),
      throwsStateError,
    );
    expect(state.released, isTrue);
  });
}
