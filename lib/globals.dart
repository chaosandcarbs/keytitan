import 'dart:ffi' hide Size;
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

// Named route constants - centralised here to avoid string literals scattered
// across the codebase.
class KeyTitan {
  static const String home = '/';
  static const String newFile = '/new';
  static const String openFile = '/open';
  static const String cloudSync = '/sync';
  static const String passList = '/list';
  static const String settings = '/settings';
  static const String exit = '/exit';
}

bool hasIllegalFileCharacters(String test) {
  if (RegExp(r'''[<>:"'/\\|?*\x00-\x1F]''').hasMatch(test)) return false;
  return true;
}

// Metadata for the home-screen menu cards. Adding a new card only requires
// a new enum value here - the build method in main.dart iterates the list
// automatically.
enum CardInfo {
  newFile(
    label: 'New Password File',
    icon: Icons.add_moderator_outlined,
    loadState: KeyTitan.newFile,
  ),
  openFile(
    label: 'Open Password File',
    icon: Icons.file_open_outlined,
    loadState: KeyTitan.openFile,
  ),
  cloudSync(
    label: 'Google Drive Sync',
    icon: Icons.cloud_sync_outlined,
    loadState: KeyTitan.cloudSync,
  ),
  settings(
    label: 'Settings',
    icon: Icons.settings_outlined,
    loadState: KeyTitan.settings,
  ),
  exit(
    label: 'Exit KeyTitan',
    icon: Icons.exit_to_app_outlined,
    loadState: KeyTitan.exit,
  );

  final String label;
  final IconData icon;
  final String loadState;

  const CardInfo({
    required this.label,
    required this.icon,
    required this.loadState,
  });
}

// App-wide style constants. Layout values (cardHeight etc.) are mutable
// because main.dart adjusts them per-platform after the first frame.
class Constants {
  // --- Colours ---
  static const Color appBarColor = Color.fromARGB(255, 26, 47, 92);
  static const Color backColor = Color(0xFF101416);
  static const Color cardColor = Color.fromARGB(255, 40, 60, 90);
  static const Color dialogColor = Color.fromARGB(255, 40, 60, 80);
  static const Color lightText = Colors.white70;

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  // True when running on a touch-first device.
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static final BoxDecoration backgroundDecoration = BoxDecoration(
    color: backColor,
    image: DecorationImage(
      image: const AssetImage('assets/keytitan_background.png'),
      opacity: 0.25,
      fit: BoxFit.cover,
    ),
  );

  static const ColorScheme colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color.fromARGB(255, 25, 66, 138),
    onPrimary: Colors.white,
    secondary: Colors.orangeAccent,
    onSecondary: Colors.black,
    error: Colors.redAccent,
    onError: Colors.white,
    surface: cardColor,
    onSurface: Colors.white,
  );

  // --- Layout & spacing (set per-platform in main.dart) ---
  static double cardHeight = 120.0;
  static double cardSepHeight = 20.0;
  static double cardIconSize = 24.0;
  static const double footerButtonSize = 32.0;

  // --- Typography ---
  static double titleTextSize = 24.0;
  static double menuTextSize = 12.0;

  // --- Password generation bounds ---
  static const int defaultPassLength = 15;
  static const int maxPassLength = 32;
  static const int minPassLength = 7;
}

// Standard AppBar used on most screens.
AppBar genTitanAppBar(String title) {
  return AppBar(
    leading: Image.asset(
      'assets/keytitan_nobkg.png',
      fit: BoxFit.contain,
      alignment: Alignment.centerRight,
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: Constants.titleTextSize.toDouble(),
        fontWeight: FontWeight.w300,
        letterSpacing: 1.2,
      ),
    ),
    centerTitle: true,
    elevation: 4,
  );
}

// Thin branding strip shown at the bottom of entry screens.
Widget bottomBar(BuildContext context) {
  return Container(
    height: 30,
    width: double.infinity,
    color: Constants.appBarColor,
    child: const Center(
      child: Text(
        'KeyTitan | From Chaos And Carbs',
        style: TextStyle(color: Colors.white54, fontSize: 10),
      ),
    ),
  );
}

// Password-character-set presets. The integer value is stored in the DB
// so existing entries remain readable if new levels are added in future.
enum Complexity {
  alpha(text: 'Alphanumeric [A-Za-z0-9]', value: 0),
  basic(text: 'Basic [A-Za-z0-9!#&\$]', value: 1),
  full(text: 'Full; [A-Za-z0-9()[]!#&\$+-,.]', value: 2),
  luda(text: 'Ludicrous Mode', value: 3);

  final int value;
  final String text;

  const Complexity({required this.value, required this.text});

  String get alphabet => getAlphabet();

  String getAlphabet() {
    switch (value) {
      case 0:
        return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      case 1:
        return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#&\$';
      case 2:
        return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()[]!#&\$+-,.';
      case 3:
        return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!"#\$%@^&*()+,.-/\':;<>=?\\[]_`{}|~';
      default:
        return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#&\$';
    }
  }

  // Maps the display text back to its enum value (used by the complexity
  // drop-down in the password dialog).
  static Complexity getComplexity(String displayText) {
    return Complexity.values.firstWhere(
      (c) => c.text == displayText,
      orElse: () => Complexity.basic,
    );
  }
}

// Helper for Vault File management
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
    if (hasIllegalFileCharacters(trimmed)) return null;
    if (!hasVaultExtension(trimmed)) return null;

    final baseName = p.basename(trimmed);
    return baseName == trimmed ? baseName : null;
  }
}

// Reusable styled button that keeps the UI consistent across screens.
class TitanButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final double? width;
  final double height;
  final Color color;

  const TitanButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.width,
    required this.height,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      color: Constants.lightText,
      fontSize: Constants.menuTextSize,
    );
    final buttonStyle = ElevatedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28.0)),
      fixedSize: Size(width ?? double.maxFinite, height),
      backgroundColor: color,
    );

    if (icon != null) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon,
            color: Constants.lightText, size: Constants.menuTextSize + 6),
        label: Text(label, style: textStyle),
        style: buttonStyle,
      );
    }

    return ElevatedButton(
      onPressed: onPressed,
      style: buttonStyle,
      child: Text(label, style: textStyle),
    );
  }
}
