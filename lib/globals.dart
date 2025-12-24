import 'package:flutter/material.dart';

/// Centralized Route Names to prevent typos across the app
class KeyTitan {
  static const String home = '/';
  static const String newFile = '/new';
  static const String openFile = '/open';
  static const String cloudSync = '/sync';
  static const String passList = '/list';
  static const String exit = '/exit';
}

/// Enhanced Enum to store metadata for the Home Screen buttons.
/// This removes the need for mapping logic inside the UI.
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

/// Global configuration and styling constants
class Constants {
  // --- Colors ---
  static const Color appBarColor = Color(0xFF263238); // BlueGrey 900
  static const Color backColor = Color(0xFF101416);   // Darker background
  static const Color cardColor = Color(0xFF37474F);   // BlueGrey 800
  static const Color lightText = Colors.white70;

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
    primary: Colors.blueGrey,
    onPrimary: Colors.white,
    secondary: Colors.orangeAccent,
    onSecondary: Colors.black,
    error: Colors.redAccent,
    onError: Colors.white,
    surface: cardColor,
    onSurface: Colors.white,
  );

  // --- Layout & Spacing ---
  // These are updated dynamically in main.dart based on platform
  static double cardHeight = 120.0;
  static double cardSepHeight = 20.0;
  static const double cardIconSpacing = 20;
  
  // --- Typography ---
  static double titleTextSize = 24.0;
  static double menuTextSize = 12.0;

  // --- Password Constants ---
  static const int defaultPassLength = 15;
  static const int maxPassLength = 32;
  static const int minPassLength = 7;


// --- Global UI Components ---

}

/// Standard AppBar used across most screens
AppBar genTitanAppBar(String title) {
  return AppBar(
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

/// Standard Bottom Bar for context/branding
Widget bottomBar(BuildContext context) {
  return Container(
    height: 30,
    width: double.infinity,
    color: Constants.appBarColor,
    child: const Center(
      child: Text(
        'KeyTitan | Secure & Local',
        style: TextStyle(color: Colors.white54, fontSize: 10),
      ),
    ),
  );
}

enum Complexity {
  alpha(text: 'Alphanumeric [A-Za-z0-9]', value: 0),
  basic(text: 'Basic [A-Za-z0-9!#&\$]', value: 1),
  full(text: 'Full; [A-Za-z0-9()[]!#&\$+-,.]', value: 2),
  luda(text: 'Ludicrous Mode', value: 3);
  
  final int value;
  final String text;

  String get alphabet => getAlphabet();
  
  String getAlphabet() {
    switch(value){
        case 0: //alphanumeric [A-Za-z0-9]
          return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        case 1: //Basic; [A-Za-z0-9!#&$]
          return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#&\$';
        case 2: //Full; [A-Za-z0-9()[]!#&$+-,.]
          return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()[]!#&\$+-,.';
        case 3: //Ludicrous; all ASCII characters
          return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!"#\$%@^&*()+,.-/\':;<>=?\\[]_`{}|~';
        default: // assume basic
          return 'abcdefghijklmnopqrstuvwxzyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#&\$';
    }
  }

  static Complexity getComplexity(String input) {
    if (input == Complexity.alpha.text){
      return Complexity.alpha;
    }
    else if (input == Complexity.basic.text){
      return Complexity.basic;
    }
    else if (input == Complexity.full.text){
      return Complexity.full;
    }
    else if (input == Complexity.luda.text){
      return Complexity.luda;
    }  
    else {
      return Complexity.basic;
    }          
  }

  const Complexity({
    required this.value,
    required this.text,
  });
}


/// Reusable Styled Button to maintain UI consistency
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
    final textStyle = TextStyle(color: Constants.lightText, fontSize: Constants.menuTextSize);
    
    final buttonStyle = ElevatedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28.0)),
      fixedSize: Size(width ?? double.maxFinite, height),
      backgroundColor: color,
    );

    if (icon != null) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: Constants.lightText, size: Constants.menuTextSize+6),
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