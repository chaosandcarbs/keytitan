import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_size/window_size.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'new.dart';
import 'open.dart';
import 'drivesync.dart';
import 'passlist.dart';
import 'settings.dart';
import 'globals.dart';

void main() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    _initDesktop();
  } else if (Platform.isAndroid || Platform.isIOS) {
    _initMobile();
  }

  runApp(const KeyTitanApp());
}

// One-time setup for desktop targets (Windows, Linux, macOS).
// Configures the window frame, prevents accidental close, and initialises
// the sqflite FFI layer used for in-memory SQLite.
void _initDesktop() async {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(550, 950),
    center: true,
    title: 'KeyTitan Password Manager',
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setPreventClose(true);
  });

  // Centre the window after the engine is fully ready.
  Future.delayed(const Duration(milliseconds: 500), () {
    setWindowFrame(
      Rect.fromCenter(center: const Offset(1000, 500), width: 512, height: 910),
    );
  });

  Constants.titleTextSize = 26;
  Constants.menuTextSize = 16;
}

// One-time setup for Android and iOS.
// sqflite_common_ffi is used on both platforms so that in-memory databases
// work consistently with the desktop code path.
void _initMobile() {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Constants.menuTextSize = 16.0;
  Constants.titleTextSize = 21.0;
  Constants.cardSepHeight = 45;
  Constants.cardHeight = 185;
  Constants.cardIconSpacing = 10.0;
  Constants.cardIconSize = 16.0;
}

class KeyTitanApp extends StatelessWidget {
  const KeyTitanApp({super.key});

  static final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KeyTitan Password Manager',
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blueGrey,
        appBarTheme: const AppBarTheme(
          backgroundColor: Constants.appBarColor,
          foregroundColor: Constants.lightText,
        ),
        colorScheme: Constants.colorScheme,
      ),
      routes: {
        KeyTitan.home: (context) => KeyTitanHome(
              title: 'KeyTitan Password Manager',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.newFile: (context) => KeyTitanNew(
              title: 'New Password File',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.openFile: (context) => KeyTitanOpen(
              title: 'Open File',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.cloudSync: (context) => KeyTitanSync(
              title: 'Drive Sync',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.passList: (context) => KeyTitanList(
              title: 'Password List',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.settings: (context) => KeyTitanSettings(
              title: 'Settings',
              navigatorKey: _navigatorKey,
            ),
        KeyTitan.exit: (context) => KeyTitanExit(
              title: 'Exiting',
              navigatorKey: _navigatorKey,
            ),
      },
    );
  }
}

// Landing screen — renders the home-screen menu cards defined in CardInfo.
class KeyTitanHome extends StatefulWidget {
  const KeyTitanHome({
    super.key,
    required this.title,
    required this.navigatorKey,
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
    final height = MediaQuery.of(context).size.height;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      Constants.cardHeight = height * 0.125;
      Constants.cardSepHeight = height * 0.043;
    } else {
      Constants.cardHeight = height * 0.1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards = CardInfo.values.toList();

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
          itemCount: cards.length,
          separatorBuilder: (_, __) => Divider(
            height: Constants.cardSepHeight,
            thickness: 0,
            color: Colors.transparent,
          ),
          itemBuilder: (context, index) {
            final info = cards[index];
            return TitanButton(
              label: info.label,
              icon: info.icon,
              onPressed: () =>
                  widget.navigatorKey.currentState!.pushNamed(info.loadState),
              height: Constants.cardHeight,
              color: Constants.cardColor,
            );
          },
        ),
      ),
    );
  }
}

// Confirmation screen shown when the user chooses to exit the app.
class KeyTitanExit extends StatefulWidget {
  const KeyTitanExit({
    super.key,
    required this.title,
    required this.navigatorKey,
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
    await Future.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final buttonWidth = MediaQuery.of(context).size.width / 3;

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
