import 'package:path/path.dart' as p;

class KeyTitanVaultFiles {
  KeyTitanVaultFiles._();

  static const extension = '.ktn';
  static const pickerExtension = 'ktn';

  static bool hasVaultExtension(String path) {
    return p.extension(path).toLowerCase() == extension;
  }

  // Drive downloads must resolve to a plain filename, never a path fragment.
  static String? safeFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(trimmed)) return null;
    if (!hasVaultExtension(trimmed)) return null;

    final baseName = p.basename(trimmed);
    return baseName == trimmed ? baseName : null;
  }
}
