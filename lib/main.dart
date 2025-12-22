// ignore_for_file: camel_case_types

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_size/window_size.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'new.dart';
import 'open.dart';
import 'drivesync.dart';
import 'passlist.dart';
import 'globals.dart';

void main() {
  if (Platform.isWindows || Platform.isLinux) {
    WidgetsFlutterBinding.ensureInitialized();

    //init sqflite
    sqfliteFfiInit();

    // Set Window Size
    setWindowMaxSize(const Size(576, 1024));
    setWindowMinSize(const Size(393, 873));
    Future<Null>.delayed(Duration(milliseconds: 500), () {
      setWindowFrame(
        Rect.fromCenter(center: Offset(1000, 500), width: 512, height: 910),
      );
    });

    Constants.titleTextSize = 34;
    Constants.menuTextSize = 28;
  }
  databaseFactory = databaseFactoryFfi;
  runApp(KeyTitanApp());
}

class KeyTitanApp extends StatelessWidget {
  KeyTitanApp({super.key});
  final _mainNavigatorKey = GlobalKey<NavigatorState>();

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows || Platform.isLinux) {
      Constants.cardHeight = MediaQuery.of(context).size.height * 0.16;
      Constants.cardSepHeight = MediaQuery.of(context).size.height * 0.075;
    } else {
      Constants.cardHeight = MediaQuery.of(context).size.height * 0.12;
    }
    return MaterialApp(
      title: 'KeyTitan Password Manager',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        appBarTheme: AppBarTheme(
          backgroundColor: Constants.appBarColor,
          foregroundColor: Constants.lightText,
        ),
        colorScheme: Constants.colorScheme,
      ),
      
      navigatorKey: _mainNavigatorKey,
      routes: {
        KeyTitan.home:
            (context) => keyTitanHome(
              title: 'KeyTitan Password Manager',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.newFile:
            (context) => keyTitanNew(
              title: 'New Password File',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.openFile:
            (context) => keyTitanOpen(
              title: 'Open File',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.cloudSync:
            (context) => keyTitanSync(
              title: 'Drive Sync',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.passList:
            (context) => keyTitanList(
              title: 'Password List',
              navigatorKey: _mainNavigatorKey,
            ),
        KeyTitan.exit:
            (context) => keyTitanExit(
              title: 'Exiting',
              navigatorKey: _mainNavigatorKey
            )
      },
    );
  }
}


class keyTitanHome extends StatefulWidget {
  // ignore: use_super_parameters
  const keyTitanHome({Key? key, required this.title, required this.navigatorKey})
    : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<keyTitanHome> createState() => _keyTitanHomeState();
}

class _keyTitanHomeState extends State<keyTitanHome> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),      
      backgroundColor: Constants.backColor,
      body: Flex(
        direction: Axis.vertical,
        clipBehavior: Clip.antiAlias,
        children: [
          Container(
            decoration: Constants.backgroundDecoration,
            child: Container(
              child: ListView.separated(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                scrollDirection: Axis.vertical,
                padding: EdgeInsets.symmetric(
                  vertical: Constants.cardSepHeight / 4,
                  horizontal: 20,
                ),
                itemCount: CardInfo.values.length,
                itemBuilder: (BuildContext context, int index) {
                  var myCards =
                      CardInfo.values.map((CardInfo info) {
                        return ElevatedButton.icon(
                          onPressed: () {
                            widget.navigatorKey.currentState!.pushNamed(
                              info.loadState,
                            );
                          },
                          label: Text(info.label, style: TextStyle(
                              color: Constants.lightText,
                            ),),
                          icon: Icon(info.icon, color: Constants.lightText),
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28.0),
                            ),
                            padding: EdgeInsets.zero,
                            fixedSize: Size(10, Constants.cardHeight),
                            backgroundColor: Constants.cardColor,
                            //shadowColor: Constants.appBarShadow,
                          ),
                        );
                      }).toList();
                  return myCards[index];
                },
                separatorBuilder:
                    (BuildContext context, int index) =>
                        Divider(height: Constants.cardSepHeight, thickness: 0, color: Constants.lightText,),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class keyTitanExit extends StatefulWidget {
  const keyTitanExit({Key? key, required this.title, required this.navigatorKey})
      : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<keyTitanExit> createState() => _keyTitanExitState();
}

class _keyTitanExitState extends State<keyTitanExit> {
  bool _exiting = false;

  Future<void> _gracefulExit() async {
    if (_exiting) return;
    setState(() => _exiting = true);

    // TODO: add any cleanup here (close DB, flush caches, etc.)
    await Future.delayed(const Duration(milliseconds: 200));

    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      backgroundColor: Constants.backColor,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Are you sure you want to exit?',
              style: TextStyle(
                fontSize: Constants.menuTextSize.toDouble(),
                color: Constants.lightText,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_exiting) const CircularProgressIndicator(),
            if (!_exiting)
              Row(mainAxisSize: MainAxisSize.min, children: [
                ElevatedButton(
                  onPressed: () => widget.navigatorKey.currentState!.pop(),
                  child: const Text('Cancel'),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20.0),
                    ),
                    padding: EdgeInsets.zero,
                    fixedSize: Size(
                      MediaQuery.of(context).size.width / 3,
                      Constants.cardHeight/2,
                    ),
                    backgroundColor: Constants.cardColor,
                    //shadowColor: Constants.appBarShadow,
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _gracefulExit,
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20.0),
                    ),
                    padding: EdgeInsets.zero,
                    fixedSize: Size(
                      MediaQuery.of(context).size.width / 3,
                      Constants.cardHeight/2,
                    ),
                    backgroundColor: Colors.orangeAccent,
                    //shadowColor: Constants.appBarShadow,
                  ),
                  child: const Text('Exit'),

                ),
              ]),
          ]),
        ),
      ),
    );
  }
}
