import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartArgon2State;

import 'sensitive.dart';

/// Consumes [state], wiping its entire workspace before releasing it.
Future<Uint8List> deriveAndClearArgon2id(
  DartArgon2State state, {
  required Uint8List password,
  required Uint8List salt,
}) async {
  ByteBuffer? workspace;
  List<int>? derived;
  try {
    workspace = state.getBlock(lane: 0, slice: 0, index: 0).buffer;
    derived = await state.deriveKeyBytes(password: password, nonce: salt);
    return Uint8List.fromList(derived);
  } finally {
    wipeBytes(derived);
    try {
      wipeBytes(workspace?.asUint8List());
    } finally {
      state.tryReleaseMemory();
    }
  }
}
