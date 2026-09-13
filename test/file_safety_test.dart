import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/globals.dart';
import 'package:keytitan/secstore.dart';
import 'package:keytitan/vault_format.dart';

void main() {
  test('vault creation detects case-insensitive filename conflicts', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_names_');
    try {
      final existing = File('${dir.path}/Personal.KTN');
      await existing.writeAsBytes([1, 2, 3]);

      expect(
        await KeyTitanVaultFiles.findExistingVault(dir.path, 'personal.ktn'),
        existing.path,
      );
      expect(
        await KeyTitanVaultFiles.findExistingVault(dir.path, 'work.ktn'),
        isNull,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('invalid download leaves an existing vault unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_download_');
    final destination = File('${dir.path}/vault.ktn');
    final original = List<int>.generate(64, (index) => index);
    try {
      await destination.writeAsBytes(original, flush: true);

      await expectLater(
        writeVaultDownloadAtomically(
          source: Stream.value(List<int>.filled(64, 0)),
          destinationPath: destination.path,
          replaceExisting: true,
        ),
        throwsA(isA<FormatException>()),
      );

      expect(await destination.readAsBytes(), original);
      expect(await dir.list().length, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('interrupted download leaves an existing vault unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_download_');
    final destination = File('${dir.path}/vault.ktn');
    final original = List<int>.generate(64, (index) => index);
    try {
      await destination.writeAsBytes(original, flush: true);

      await expectLater(
        writeVaultDownloadAtomically(
          source: Stream<List<int>>.error(StateError('network interrupted')),
          destinationPath: destination.path,
          replaceExisting: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await destination.readAsBytes(), original);
      expect(await dir.list().length, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('validated legacy KTN3 download replaces only after completion',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_download_');
    final destination = File('${dir.path}/vault.ktn');
    final downloaded = <int>[
      0x4b,
      0x54,
      0x4e,
      0x33,
      ...List<int>.filled(45, 7),
    ];
    try {
      await destination.writeAsBytes(List<int>.filled(64, 1), flush: true);

      await writeVaultDownloadAtomically(
        source: Stream.value(downloaded),
        destinationPath: destination.path,
        replaceExisting: true,
      );

      expect(await destination.readAsBytes(), downloaded);
      expect(await dir.list().length, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('structured KTN4 download is accepted by the sync safety check',
      () async {
    final dir = await Directory.systemTemp.createTemp('keytitan_download_');
    final destination = File('${dir.path}/vault.ktn');
    final downloaded = Uint8List(KeyTitanVaultCodec.v4MinimumLength);
    downloaded.setRange(0, 4, KeyTitanVaultCodec.v4Magic);
    final view = ByteData.sublistView(downloaded);
    view.setUint32(4, KeyTitanVaultCodec.v4HeaderLength, Endian.big);
    view.setUint32(8, KeyTitanVaultCodec.argonMemoryKiB, Endian.big);
    view.setUint32(12, KeyTitanVaultCodec.argonIterations, Endian.big);
    view.setUint32(16, KeyTitanVaultCodec.argonParallelism, Endian.big);
    view.setUint64(112, 1, Endian.big);

    try {
      await writeVaultDownloadAtomically(
        source: Stream.value(downloaded),
        destinationPath: destination.path,
      );

      expect(await destination.readAsBytes(), downloaded);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
