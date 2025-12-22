import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:googleapis/drive/v3.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'globals.dart';
import 'secstore.dart';

class keyTitanSync extends StatefulWidget {
  const keyTitanSync({Key? key, required this.title, required this.navigatorKey})
    : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<keyTitanSync> createState() => _keyTitanSyncState();
}

class _keyTitanSyncState extends State<keyTitanSync> {
  // ignore: prefer_final_fields
  Key _refreshKey = UniqueKey();
  bool authenticated = false;
  List<String> scopes = ['https://www.googleapis.com/auth/drive.metadata',
    'https://www.googleapis.com/auth/drive.file', 'https://www.googleapis.com/auth/drive.readonly'];
  String _body = 'Please authenticate';
  List<String> lKTFiles = [];
  List<File> KTFiles = [];
  var KTPathCon = TextEditingController();


  @override
  void dispose() {
    KTPathCon.dispose();
    super.dispose();
  }

  void driveAuth() async {
    String clientID = '';
    debugPrint('Attempting Authentication');
    //AutoRefreshingAuthClient hClient = AutoRefreshingAuthClient();
    try{ 
      debugPrint('creating signin');
      GoogleDrive oauth2 = GoogleDrive(); 
      var hClient = await oauth2.getHttpClient();

      debugPrint('grabbing files');
      DriveApi myDrive = DriveApi(hClient);
      FileList fileList = await myDrive.files.list();
      for(int i = 0; i < fileList.files!.length; i++) {
        File temp = fileList.files![i];
        if(temp.name!.endsWith('.ktn')){
          KTFiles.add(temp);
          debugPrint('ID  : ${temp.id}');
          debugPrint('Name: ${temp.name}');
        }
      }
      debugPrint('updating state');
      setState(() {
        
        authenticated = true;
        _refreshKey = UniqueKey();
      });
    }
    catch(e) {
      debugPrint(e.toString());
    }
  }

  void driveUpload() {
    debugPrint('Uploading');
    _refreshKey = UniqueKey();
  }

  Future<void> _handleGetDrive() async {
    setState(() { 
      //debugPrint(_currentUser?.displayName.toString());
    });
  }

  void pickDirectory() async {
    lKTFiles = [];
    final docsDir = await getApplicationDocumentsDirectory();
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(initialDirectory: docsDir.path);
    if (selectedDirectory != null) {
      KTPathCon.text = selectedDirectory;
      try{
        List<FileSystemEntity> localList = await Directory(KTPathCon.text).list().toList();
        for(int i = 0; i < localList.length; i++) {
          String tName = basename(localList[i].path);
          if(tName.endsWith('.ktn')){
            lKTFiles.add(tName);
          }
        }
      }
      catch(e) { debugPrint('$e'); }      
    } else {
      KTPathCon.text = '';
    }
    _refreshKey = UniqueKey();
  }

  @override
  Widget build(BuildContext context) {
    var height = MediaQuery.of(context).size.height;
    var width = MediaQuery.of(context).size.width;
    var btnWidth = width / 2;
    var btnHeight = height / 10;
    KTPathCon.text ??= '';
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),      
      backgroundColor: Constants.backColor,
      body: Flex(
        direction: Axis.vertical,
        clipBehavior: Clip.antiAlias,
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              vertical: 20,
              horizontal: 20,
            ),
            decoration: Constants.backgroundDecoration,
            height: height*0.92,
            child: Column(
              key: _refreshKey,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              spacing: height*0.03,
              children: [
                ElevatedButton.icon(
                  onPressed: !authenticated ? pickDirectory : null,
                  label: Text('1) Pick a Local Directory\n${KTPathCon.text}', style: TextStyle(
                      color: Constants.lightText,
                    ),),
                  icon: Icon(Icons.folder, color: Constants.lightText),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28.0),
                    ),
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnWidth, btnHeight),
                    backgroundColor: Constants.cardColor,
                    disabledBackgroundColor: Constants.appBarShadow,
                    disabledForegroundColor: Constants.cardColor                    
                  ),
                ),                
                ElevatedButton.icon(
                  onPressed: !authenticated ? driveAuth : null,
                  label: Text('2) Authenticate With Drive', style: TextStyle(
                      color: Constants.lightText,
                    ),),
                  icon: Icon(Icons.login, color: Constants.lightText),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28.0),
                    ),
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnWidth, btnHeight),
                    backgroundColor: Constants.cardColor,
                    disabledBackgroundColor: Constants.appBarShadow,
                    disabledForegroundColor: Constants.cardColor                    
                  ),
                ),
                Divider(height: height*0.05, thickness: 0, color: Constants.lightText,),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Column( children: [
                      Text(
                        'Local Files',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Constants.lightText,
                        ),
                      ),
                      Container(
                        height: height*.3,
                        width: width*.45,
                        child: ListView.separated(
                          padding: EdgeInsets.all(10),
                          itemBuilder: (BuildContext context, int index) {
                            return Container(
                              height: 50,
                              color: Constants.cardColor,
                              child: Center(child: Text(lKTFiles[index], style: TextStyle(color: Constants.lightText),),),
                            );
                          }, 
                          separatorBuilder: (BuildContext context, int index) => const Divider(), 
                          itemCount: lKTFiles.length
                        )
                      )
                    ]),
                    VerticalDivider(width: 1, thickness: 5,),
                    Column( children: [
                      Text(
                        'Drive Files',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Constants.lightText,
                        ),
                      ),
                      Container(
                        height: height*.3,
                        width: width*.45,
                        child: ListView.separated(
                          padding: EdgeInsets.all(10),
                          itemBuilder: (BuildContext context, int index) {
                            String rname = KTFiles[index].name as String;
                            return Container(
                              height: 50,
                              color: Constants.cardColor,
                              child: Center(child: Text(rname, style: TextStyle(color: Constants.lightText)),),
                            );
                          }, 
                          separatorBuilder: (BuildContext context, int index) => const Divider(), 
                          itemCount: KTFiles.length
                        )
                      )
                    ],)
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: authenticated ? driveUpload : null,
                  label: Text('3) Upload To Drive', style: TextStyle(
                      color: Constants.lightText,
                    ),),
                  icon: Icon(Icons.login, color: Constants.lightText),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28.0),
                    ),
                    padding: EdgeInsets.zero,
                    fixedSize: Size(btnWidth, btnHeight),
                    backgroundColor: Constants.cardColor,
                    disabledBackgroundColor: Constants.appBarShadow,
                    disabledForegroundColor: Constants.cardColor
                  ),
                ),
              ],
            ),
          ),
        ]
      )
    );
  }
}