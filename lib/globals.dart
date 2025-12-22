import 'dart:core';
import 'package:flutter/material.dart';

class KeyTitan {
  static const home = '/';
  static const newFile = '/newFile';
  static const openFile = '/openFile';
  static const passList = '/passList';
  static const cloudSync = '/cloudSync';
  static const exit = '/exit';
}

class Constants {
  static const double paddingSmall = 8.0;
  static double titleTextSize = 25;
  static double menuTextSize = 23;
  static double cardHeight = 75;
  static double cardSepHeight = 75;
  static const appBarColor = Color.fromARGB(255, 13, 36, 66);//0xFF1D3658
  static const appBarShadow = Color.fromARGB(255, 38, 48, 56); 
  static const backColor = Color(0xFF1D3658);//0xFF0D1B3E
  static const Color cardColor = Color.fromARGB(255, 13, 36, 66);//0xFF124C73
  static const lightText = Color(0xFFE6D9C3);
  static const darkText = Color(0xFF1D3658);
  static const semiLightText = Color(0xFFB2BBBE);
  static const drawerColor = Color(0xFF546E7A); //shade600
  static var colorScheme = ColorScheme.fromSeed(seedColor: Colors.blueGrey);
  static const backgroundImage = AssetImage('assets/keytitan_background.png');
  static const backgroundDecoration = BoxDecoration(image: DecorationImage(image: backgroundImage,fit: BoxFit.fill,opacity: 0.3,),);
  static double defaultPassLength = 20;
  static double minPassLength = 8;
  static double maxPassLength = 40;
}

Widget bottomBar(BuildContext context) {
  return Container(color: Constants.appBarColor, height: 40);
}

genTitanAppBar(String appTitle) {
  var leading = true; 
  if (appTitle == 'Password List') { 
    leading = false; 
  }
  return AppBar(
    centerTitle: true,
    toolbarHeight: 60,
    automaticallyImplyLeading: leading,
    title: Row(
      children: [
        Expanded(
          child: Text(
            appTitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Constants.titleTextSize),
          ),
        ),
        CircleAvatar(
          backgroundImage: AssetImage('assets/keytitan_rounded.png'),
          radius: 30,
          backgroundColor: Constants.appBarShadow,
        ),
      ],
    ),
  );
}

enum CardInfo {
  newCard('New Password File', KeyTitan.newFile, Icons.enhanced_encryption),
  openCard('Open Password File', KeyTitan.openFile, Icons.lock_open),
  //listCard('Password List', KeyTitan.passList, Icons.),
  cloudCard('Sync With Google Drive', KeyTitan.cloudSync, Icons.vpn_lock),
  exitCard('Close KeyTitan', KeyTitan.exit, Icons.exit_to_app);

  const CardInfo(this.label, this.loadState, this.icon);
  final String label;
  final String loadState;
  final IconData icon;
}

enum Complexity {
  alpha(text: 'Alphanumeric [A-Za-z0-9]', value: 0),
  basic(text: 'Basic [A-Za-z0-9!#&\$]', value: 1),
  full(text: 'Full; [A-Za-z0-9()[]!#&\$+-,.]', value: 2),
  luda(text: 'Ludicrous Mode', value: 3);

  const Complexity({
    required this.value,
    required this.text,
  });

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
}