import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
//import 'package:keytitan/path.dart';
import 'passwords.dart';
import 'globals.dart';

class keyTitanNew extends StatefulWidget {
  const keyTitanNew({Key? key, required this.title, required this.navigatorKey})
    : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<keyTitanNew> createState() => _keyTitanNewState();
}

class _keyTitanNewState extends State<keyTitanNew> {
  var fileNameCon = TextEditingController();
  var fileDispCon = TextEditingController();
  var filePathCon = TextEditingController();
  var filePassCon = TextEditingController();
  var fileVerfCon = TextEditingController();

  @override
  void dispose() {
    fileNameCon.dispose();
    filePathCon.dispose();
    fileDispCon.dispose();
    filePassCon.dispose();
    fileVerfCon.dispose();
    super.dispose();
  }

  String? passValidator(String? pass1, String pass2) {
    if (pass1 == null || pass1 == '') {
      return 'Please enter a password!';
    } else if (pass1 != pass2) {
      return 'Passwords don\'t match!';
    }
    return null;
  }

    String? fileValidator(String? inFile, String? filePath) {
    if (inFile == null || inFile == '') {
      return 'Please enter a valid filename!';
    } 
    else if (filePath == null || filePath == '') {
      return 'Please choose a valid directory!';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final _formKey = GlobalKey<FormState>();
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),      
      backgroundColor: Constants.backColor,
      body: Container(
         decoration: Constants.backgroundDecoration,
        child: Form(
          key: _formKey,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Text('Pick Directory: ', style: TextStyle(color: Constants.lightText),),
                      TextButton(
                        onPressed: () {
                          pickDirectory();
                        },
                        child: Text('Click to Choose Directory', style: TextStyle(color: Constants.lightText),),
                      ),
                      Spacer(flex: 1,)
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Expanded(flex: 2, child: TextFormField(controller: filePathCon, enabled: false,style: TextStyle(color: Constants.lightText)),),
                      Spacer(flex: 1,),
                    ]
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 2,),
                      Expanded(flex: 3, child: Text('File Name:   ', style: TextStyle(color: Constants.lightText),)),
                      Expanded(flex: 6, child: TextFormField(
                        controller: fileNameCon,
                        style: TextStyle(
                          color: Constants.lightText
                        ),
                        validator: (String? inFile) {
                          return fileValidator(inFile, filePathCon.text);
                        },
                      )),
                      Expanded(flex: 3, child: Text('.ktn', style: TextStyle(color: Constants.lightText),)),
                      Spacer(flex: 1,)
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Expanded(flex: 2, child: Text('Password:  ', style: TextStyle(color: Constants.lightText),)),
                      Expanded(flex: 4, child: TextFormField(
                        controller: filePassCon, 
                        obscureText: true,
                        style: TextStyle(color: Constants.lightText),
                        validator: (String? pass1) {
                          return passValidator(pass1, fileVerfCon.text);
                        },
                      )),
                      Spacer(flex: 1,)
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Expanded(flex: 2, child: Text('Verify:  ', style: TextStyle(color: Constants.lightText),)),
                      Expanded(flex: 4, child: TextFormField(
                        controller: fileVerfCon, 
                        obscureText: true,
                        style: TextStyle(color: Constants.lightText),
                        validator: (String? pass2) {
                          return passValidator(pass2, filePassCon.text);
                        },
                      )),
                      Spacer(flex: 1,),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: ElevatedButton(
                      onPressed: () {
                        if (_formKey.currentState!.validate()){
                          createPassFile();
                        }
                      },
                      child: Text('Create File'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void pickDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(initialDirectory: docsDir.path);
    if (selectedDirectory != null) {
      filePathCon.text = selectedDirectory;
    } else {
      filePathCon.text = '';
    }
  }

  void createPassFile() {
    var file = fileNameCon.text;
    var path = filePathCon.text;
    var pass = filePassCon.text;

    String? fileName = '$path${Platform.pathSeparator}$file.ktn';
    passFile pFile = passFile(fileName, pass);
    debugPrint('New File: ${pFile.fileName}');
    debugPrint('Popping new Navi off stack');
    //pop the dialog box
    NavigatorState navi = widget.navigatorKey.currentState!;
    Navigator.of(this.context, rootNavigator: true).pop();
    Navigator.pushNamed(this.context, KeyTitan.passList, arguments: pFile);
    
  }
}