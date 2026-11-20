import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keytitan/vault_storage.dart';

// A separate OS process, so the race test exercises the native commit lock.
Future<void> main(List<String> arguments) async {
  stdout.writeln('ready');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  try {
    await VaultFileCommit.writeBytes(
      File(arguments[0]),
      Uint8List.fromList(utf8.encode(arguments[2])),
      expectedFingerprint: arguments[1],
    );
    stdout.writeln('saved');
  } on VaultFileConflict {
    stdout.writeln('conflict');
  }
}
