import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_size/window_size.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:window_manager/window_manager.dart';

// Local imports
import 'new.dart';
import 'open.dart';
import 'drivesync.dart';
import 'passlist.dart';
import 'globals.dart';

void main() {
  // Handle Desktop specific initializations
  if (Platform.isWindows || Platform.isLinux) {
    _initializeDesktopEnvironment();
    databaseFactory = databaseFactoryFfi;
  }
  if (Platform.isAndroid) {
    _initializeAndroidEnvironment();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const KeyTitanApp());
}

/// Sets up window constraints and database drivers for Desktop platforms
void _initializeDesktopEnvironment() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(550, 950),
    center: true,
    title: "KeyTitan Password Manager",
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    // Prevent the window from closing immediately so we can cleanup
    await windowManager.setPreventClose(true);
  });

  sqfliteFfiInit();

  await windowManager.setPreventClose(true);
  
  // Center the window on the screen after a brief delay to ensure engine readiness
  Future.delayed(const Duration(milliseconds: 500), () {
    setWindowFrame(
      Rect.fromCenter(center: const Offset(1000, 500), width: 512, height: 910),
    );
  });

  // Scale UI constants for desktop readability
  Constants.titleTextSize = 26;
  Constants.menuTextSize = 16;
}

void _initializeAndroidEnvironment() {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  Constants.menuTextSize = 15.0;
  Constants.titleTextSize = 20.0;
  Constants.cardSepHeight = 30;
  Constants.cardHeight = 160;
  Constants.cardIconSpacing = 10.0;
  Constants.cardIconSize = 16.0;
}


class KeyTitanApp extends StatelessWidget {
  const KeyTitanApp({super.key});

  // Global key for navigation without BuildContext if needed
  static final _mainNavigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KeyTitan Password Manager',
      navigatorKey: _mainNavigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blueGrey,
        appBarTheme: AppBarTheme(
          backgroundColor: Constants.appBarColor,
          foregroundColor: Constants.lightText,
        ),
        colorScheme: Constants.colorScheme,
      ),
      // Defined named routes for cleaner navigation management
      routes: {
        KeyTitan.home: (context) => KeyTitanHome(
              title: 'KeyTitan Password Manager',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.newFile: (context) => KeyTitanNew(
              title: 'New Password File',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.openFile: (context) => KeyTitanOpen(
              title: 'Open File',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.cloudSync: (context) => KeyTitanSync(
              title: 'Drive Sync',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.passList: (context) => KeyTitanList(
              title: 'Password List',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.exit: (context) => KeyTitanExit(
              title: 'Exiting',
              navigatorKey: _mainNavigatorKey,
            )
      },
    );
  }
}

/// The Landing Screen of the application
class KeyTitanHome extends StatefulWidget {
  const KeyTitanHome({
    super.key, 
    required this.title, 
    required this.navigatorKey
  });

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanHome> createState() => _KeyTitanHomeState();
}

class _KeyTitanHomeState extends State<KeyTitanHome> {
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize layout constants based on screen size once
    final double screenHeight = MediaQuery.of(context).size.height;
    if (Platform.isWindows || Platform.isLinux) {
      Constants.cardHeight = screenHeight * 0.155;
      Constants.cardSepHeight = screenHeight * 0.055;
    } else {
      Constants.cardHeight = screenHeight * 0.12;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Optimization: Pre-calculate the list of info to avoid mapping inside the builder
    final cardData = CardInfo.values.toList();

    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),
      backgroundColor: Constants.backColor,
      body: Container(
        decoration: Constants.backgroundDecoration,
        child: ListView.separated(
          padding: EdgeInsets.symmetric(
            vertical: Constants.cardSepHeight,
            horizontal: 20,
          ),
          itemCount: cardData.length,
          separatorBuilder: (context, index) => 
              Divider(height: Constants.cardSepHeight, thickness: 0, color: Colors.transparent),
          itemBuilder: (context, index) {
            final info = cardData[index];
            return TitanButton(
              label: info.label,
              icon: info.icon,
              onPressed: () => widget.navigatorKey.currentState!.pushNamed(info.loadState),
              height: Constants.cardHeight,
              color: Constants.cardColor,
            );
          },
        ),
      ),
    );
  }
}

/// Confirm Exit Screen with graceful shutdown logic
class KeyTitanExit extends StatefulWidget {
  const KeyTitanExit({
    super.key, 
    required this.title, 
    required this.navigatorKey
  });

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanExit> createState() => _KeyTitanExitState();
}

class _KeyTitanExitState extends State<KeyTitanExit> {
  bool _isExiting = false;

  Future<void> _gracefulExit() async {
    if (_isExiting) return;
    setState(() => _isExiting = true);

    // Placeholder for cleanup: Close DB, clear secure storage, etc.
    await Future.delayed(const Duration(milliseconds: 300));

    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final double buttonWidth = MediaQuery.of(context).size.width / 3;

    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      backgroundColor: Constants.backColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Are you sure you want to exit?',
                style: TextStyle(
                  fontSize: Constants.menuTextSize.toDouble(),
                  color: Constants.lightText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              if (_isExiting) 
                const CircularProgressIndicator()
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TitanButton(
                      label: 'Cancel',
                      onPressed: () => widget.navigatorKey.currentState!.pop(),
                      width: buttonWidth,
                      height: Constants.cardHeight / 2,
                      color: Constants.cardColor,
                    ),
                    const SizedBox(width: 16),
                    TitanButton(
                      label: 'Exit',
                      onPressed: _gracefulExit,
                      width: buttonWidth,
                      height: Constants.cardHeight / 2,
                      color: Colors.orangeAccent,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
