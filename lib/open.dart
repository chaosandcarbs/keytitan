import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'passlist.dart';
import 'globals.dart';
import 'passwords.dart';

class keyTitanOpen extends StatefulWidget {
  // ignore: use_super_parameters
  const keyTitanOpen({Key? key, required this.title, required this.navigatorKey, })//this.passFile})
    : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;
  //final String? passFile;
  
  //String? path = ModalRoute.of(context)!.settings.arguments as String?;
  //if(passFile != null){ debugPrint(passFile); }
  //else if(path != null) { debugPrint(path); }

  @override
  // ignore: no_logic_in_create_state
  State<keyTitanOpen> createState() => _keyTitanOpenState();//passFile);
}

class _keyTitanOpenState extends State<keyTitanOpen> {
  //String? passFile;
  passFile? pFile;
  var fileNameCon = TextEditingController();
  var fileDispCon = TextEditingController();
  var filePassCon = TextEditingController();
  var errorCon = TextEditingController();

  @override
  void dispose() {
    fileNameCon.dispose();
    fileDispCon.dispose();
    filePassCon.dispose();
    errorCon.dispose();
    pFile = null;
    super.dispose();
  }

  void pickFile() async {
    final docsDir = await getApplicationDocumentsDirectory();
    FilePickerResult? selectedFile = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      dialogTitle: 'Pick an encrypted file:',
      initialDirectory: docsDir.path,
      type: FileType.custom,
      allowedExtensions: ['hydra','pass','ktn']
    );
    if (selectedFile != null) {
      debugPrint('Using ${selectedFile.files.first.path}');
      fileNameCon.text = selectedFile.files.first.path!;
    } else {
      debugPrint('File picking failed');
    }
  }

  String? passValidator() {
    return null;
  }

  String? fileValidator(String? file) {
    if(file == null){
      return 'Please select a file!';
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
                      Text('Pick File: ', style: TextStyle(color: Constants.lightText),),
                      TextButton(
                        onPressed: () {
                          pickFile();
                        },
                        child: Text('Click to Choose File', style: TextStyle(color: Constants.lightText),),
                      ),
                      Spacer(flex: 1,)
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Expanded(flex: 5, child: TextFormField(controller: fileNameCon, validator: (String? file){return fileValidator(file);}, enabled: false,style: TextStyle(color: Constants.lightText)),),
                      Spacer(flex: 1,),
                    ]
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
                          return passValidator();
                        },
                      )),
                      Spacer(flex: 1,)
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: ElevatedButton(
                      onPressed: () {
                        if (_formKey.currentState!.validate()){
                          openPassFile();
                        }
                      },
                      child: Text('Open File'),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Spacer(flex: 1,),
                      Expanded(flex: 3, child: TextFormField(
                        controller: errorCon, 
                        enabled: false,
                        style: TextStyle(color: Colors.red),
                      )),
                      Spacer(flex: 1,)
                    ],
                  ),                  
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> openPassFile() async {
    debugPrint('Attempted open of existing file');
    if(fileNameCon.text != null && fileNameCon.text != '') {
      if(filePassCon.text != null && filePassCon.text != '') {
        try {
          pFile = passFile(fileNameCon.text, filePassCon.text);
          if (await pFile!.attemptDecrypt()) {
            NavigatorState navi = widget.navigatorKey.currentState!;
            Navigator.of(context, rootNavigator: true).pop();
            Navigator.pushNamed(context, KeyTitan.passList, arguments: pFile);
          }
          else {
            errorCon.text = 'Decrypt Failed';
          }
        }
        on Exception catch (exc) {
          debugPrint(exc.toString());
          errorCon.text = 'An Error Occurred During Decrypt';
        }
      }
      else {
        errorCon.text = 'Password Field Empty!';
      }
    }
    else {
      errorCon.text = 'Please Pick A File!';
    }
  }

}