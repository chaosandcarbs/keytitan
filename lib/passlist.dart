import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'globals.dart';
import 'passwords.dart';

class keyTitanList extends StatefulWidget {
  const keyTitanList({Key? key, required this.title, required this.navigatorKey})
    : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<keyTitanList> createState() => _keyTitanListState();
}

class _keyTitanListState extends State<keyTitanList> {
  final headCon = TextEditingController();
  final idCon = TextEditingController();
  final titleCon = TextEditingController();
  final siteCon = TextEditingController();
  final catCon = TextEditingController();
  final userCon = TextEditingController();
  final passCon = TextEditingController();
  final complexityCon = TextEditingController();
  // ignore: prefer_final_fields
  Key _refreshKey = UniqueKey();
  late passFile pFile;

  void dispose() {
    headCon.dispose();
    idCon.dispose();
    titleCon.dispose();
    siteCon.dispose();
    catCon.dispose();
    userCon.dispose();
    passCon.dispose();
    complexityCon.dispose();
    super.dispose();
  }

  void createPassword() async {

    await pFile.insertPassword(
      keyTitanPass(
        id: int.parse(idCon.text),
        title: titleCon.text,
        site: siteCon.text,
        category: catCon.text,
        username: userCon.text,
        password: passCon.text
      )
    );

    setState(() {
      _refreshKey = UniqueKey();
    });
    // pop the dialog box
    Navigator.of(context, rootNavigator: true).pop();
  }

  void updatePassword() async {

    await pFile.updatePassword(
      keyTitanPass(
        id: int.parse(idCon.text),
        title: titleCon.text,
        site: siteCon.text,
        category: catCon.text,
        username: userCon.text,
        password: passCon.text
      )
    );

    setState(() {
      _refreshKey = UniqueKey();
    });
    // pop the dialog box
    Navigator.of(context, rootNavigator: true).pop();
    //pop the (unrefreshed) screen
    //Navigator.of(context, rootNavigator: true).pop();
    //push new refreshed screen
    //widget.navigatorKey.currentState!.pushNamed(KeyTitan.passList, arguments: pFile);
  }

  void verifyPassFile() {
    debugPrint('Found password file');
    debugPrint('File Filename: ${pFile.fileName}');
    debugPrint('File Encryptd: ${pFile.isEncrypted}');
    debugPrint('File Password: ${pFile.password}');
    //determine if the file exists
    if(this.pFile.fileExists()){
      // should be an existing file
      if(this.pFile.isEncrypted) {
        this.pFile.attemptDecrypt();
      }
    }
    else{
      // brand new file
      this.pFile.newSQLFile();
    }
  }

  void deletePassword(int id) async {
    await pFile.deletePassword(id);
    setState(() {
      _refreshKey = UniqueKey();
    });
    Navigator.of(context, rootNavigator: true).pop();
  }

  void deletePasswordDialog(String title, int id) async {
    final _formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: EdgeInsets.all(10),
        scrollable: true,
        content: Form(
          key: _formKey,
          child: Column(
            children: [
              Text('Are you sure you want to delete $title?'),
              ElevatedButton(
                onPressed: () { deletePassword(id); },
                child: Text('Really Delete!', style: TextStyle(color: Colors.red))
              )
            ],
          ),
        ),
      )
    );
  }

  String? stringValidator(String? value, String field) {
    if (value == null || value == '') {
      return 'Please enter a valid $field';
    }
    return null;
  }

  void saveAndClose() {
    try {
      this.pFile.attemptEncrypt();
    }
    catch(except) { debugPrint(except.toString()); }
    if(this.pFile.isEncrypted){
      debugPrint('Encrypted Successfully');
    }
    closeOnly();
  }

  void closeOnly() {
    //cleanup 
    Clipboard.setData(ClipboardData(text: ''));
    this.pFile.closeFiles();
    setState(() {
      pFile.fileName = '';
      pFile.password = '';
      _refreshKey = UniqueKey();
    });

    // pop pass list
    Navigator.of(context, rootNavigator: true).pop();
  }

  void passwordDialog({bool edit = false}) async {
    if (edit) {
      headCon.text = 'Edit Password Info';
    }
    else {
      headCon.text = 'Enter New Password Info';
    }
    String btnText;
    final _formKey = GlobalKey<FormState>();
    List<DropdownMenuEntry> passwordComplexity = [
      DropdownMenuEntry(value: Complexity.alpha.value, label: Complexity.alpha.text),
      DropdownMenuEntry(value: Complexity.basic.value, label: Complexity.basic.text),
      DropdownMenuEntry(value: Complexity.full.value, label: Complexity.full.text),
      DropdownMenuEntry(value: Complexity.luda.value, label: Complexity.luda.text),
    ];
    double _passLength = Constants.defaultPassLength;
    List<DropdownMenuEntry> menuList = [];
    menuList.add(DropdownMenuEntry(value: 0, label: ''));
    List categories = await pFile.getCategories();
    for(int i = 0; i < categories.length; i++)
    {
      menuList.add(DropdownMenuEntry(value: categories[i]['id'], label: categories[i]['category']));
    }
    if (!edit || idCon.text.isEmpty || int.parse(idCon.text).isNaN){
      debugPrint('New Password Popup');
      idCon.text = '0';
      titleCon.text = '';
      siteCon.text = '';
      catCon.text = '';
      userCon.text = '';
      passCon.text = '';
      btnText = 'Create!';
    }
    else {
      debugPrint('Editing Password');
      btnText = 'Update!';
    }
    await showDialog(
      context: context, 
      builder: (context) => AlertDialog(
        contentPadding: EdgeInsets.all(10),
        scrollable: true,
        title: TextFormField(controller: headCon, enabled: false, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),),
        titlePadding: EdgeInsets.all(10),
        insetPadding: EdgeInsets.all(10),
        content: Form(
          key: _formKey,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              var height = MediaQuery.of(context).size.height;
              var width = MediaQuery.of(context).size.width;
              final catMenu = DropdownMenu(
                dropdownMenuEntries: menuList, 
                hintText: 'Category',
                label: Text('Select Category'),
                width: width*.39,
                controller: catCon,
              );
              return SizedBox(
                height: height*0.63,
                width: width*0.8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  //spacing: height*0.013,
                  children: <Widget>[
                    TextFormField(
                      controller: titleCon,
                      decoration: const InputDecoration(hintText: 'Title For Entry', label: Text('Title')),
                      validator: (String? title){ return stringValidator(title, 'title'); },
                    ),
                    TextFormField(
                      controller: siteCon,
                      decoration: const InputDecoration(hintText: 'Site Name', label: Text('Site Name')),
                      validator: (String? site) { return stringValidator(site, 'site');},
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Expanded(flex: 5,child: catMenu,),
                        Text('  OR  '),
                        Expanded(flex: 4,child: TextFormField(controller: catCon, decoration: const InputDecoration(hintText: 'New Category', label: Text('New Category'))),)
                      ]
                    ),
                    TextFormField(
                      controller: userCon,
                      decoration: const InputDecoration(hintText: 'Username'),
                      validator: (String? site) { return stringValidator(site, 'site');},
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                      Expanded(flex: 5, child: TextFormField(
                        controller: passCon,
                        //enabled: false,
                        decoration: const InputDecoration(hintText: 'Enter Password OR Use Slider/Generate'),
                        validator: (String? site) { return stringValidator(site, 'site');},
                      )),
                      Expanded(flex: 1, child: Tooltip(
                        message: 'Suggest using the complexity drop-down + slider to generate a random password, to avoid dictionary attacks',
                        triggerMode: TooltipTriggerMode.tap,
                        showDuration: Duration(seconds: 5),
                        child: Icon(Icons.info),
                      )),
                    ]),
                    Row(
                      children: [ 
                        Expanded(flex: 5, child: DropdownMenu(
                          dropdownMenuEntries: passwordComplexity,
                          initialSelection: 1,
                          label: Text('Password Complexity'),
                          controller: complexityCon,
                        ),),
                        Expanded(flex: 1, child: Tooltip(
                          message: 'Use the maximum complexity your site/application allows. \nLudicrous Mode: all ASCII printable characters.',
                          triggerMode: TooltipTriggerMode.tap,
                          showDuration: Duration(seconds: 5),
                          child: Icon(Icons.info),
                        )),
                      ],
                    ),
                    SliderTheme(
                      data: SliderThemeData(
                        showValueIndicator: ShowValueIndicator.always,
                      ),
                      child: Slider(
                        value: _passLength, 
                        label: 'Password Length: ${_passLength.toInt()}',
                        onChanged: (double value) { setState(() {
                          _passLength = value; 
                          passCon.text = keyTitanPass.genPassword(Complexity.getComplexity(complexityCon.text), _passLength.toInt());
                        });},
                        min: Constants.minPassLength,
                        max: Constants.maxPassLength,
                        divisions: (Constants.maxPassLength-Constants.minPassLength).toInt(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: ElevatedButton(
                        onPressed: (){if(_formKey.currentState!.validate()){ 
                          if(edit) {
                            updatePassword();
                          }
                          else{
                            createPassword(); 
                          }
                          }
                        }, 
                        child: Text(btnText)
                      ),
                    )
                  ],
                ),
              );
            },
          ),
        ),
      )
    );
  }


  @override
  Widget build(BuildContext context) {
    Object? sets = ModalRoute.of(context)!.settings.arguments;
    if(sets != null) {
      this.pFile = passFile.passObj(sets);
      verifyPassFile();
    }
    else{ 
      debugPrint('No password file; arrived in error'); 
    } 
    Widget passwordFooterBar = Padding(
      padding: EdgeInsets.all(10),
      child: Row(
        children: [
          Expanded(flex: 6, child: FloatingActionButton.extended(
            heroTag: 'newPassBtn',
            onPressed: passwordDialog,
            label: const Text('New Password'),
            icon: const Icon(Icons.add),
            backgroundColor: Constants.backColor,
            foregroundColor: Constants.lightText,
            extendedPadding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 25,
            ),
          )),
          Spacer(flex: 1,),
          Expanded(flex: 6, child: FloatingActionButton.extended(
            heroTag: 'saveCloseBtn',
            onPressed: saveAndClose,
            label: const Text('Save & Close'),
            icon: const Icon(Icons.save_as_outlined),
            backgroundColor: Constants.backColor,
            foregroundColor: Constants.lightText,
            extendedPadding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 25,
            ),
          )),
          Spacer(flex: 1,),
          Expanded(flex: 4, child: FloatingActionButton.extended(
            heroTag: 'closeBtn',
            onPressed: closeOnly,
            label: const Text('Close'),
            icon: const Icon(Icons.logout),
            backgroundColor: Constants.backColor,
            foregroundColor: Constants.lightText,
            extendedPadding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 25,
            ),
          )),
        ],
      ),
    );
    return FutureBuilder(
      key: _refreshKey,
      future: this.pFile.getCategories(), builder: (context, catSnap) {
        var returned = null;
        while(true){ //returned.runtimeType != Center) {
          if(catSnap.hasError) { returned = Center(child: Text(catSnap.error.toString())); }
          else if (catSnap.data != null && catSnap.data!.isNotEmpty) { 
            debugPrint('Snapshot has data: ${catSnap.data!.length}');
            List<Tab> tabList = [];
            var catData = catSnap.data;
            for(int i = 0; i < catData!.length; i++) {
              tabList.add(Tab(text: catData[i]['category'].toString(),));
            }
            return DefaultTabController(
              length: tabList.length, 
              //child: DefaultTabControllerListener(
              //  onTabChanged: (int value) { debugPrint('Tab changed'); },
                child: Scaffold( 
                  key: _refreshKey,
                  backgroundColor: Constants.backColor,
                  appBar: genTitanAppBar(widget.title),
                  bottomNavigationBar: Container(
                    height: MediaQuery.of(context).size.height*0.078,
                    width: MediaQuery.of(context).size.width,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: Constants.backgroundImage,
                        fit: BoxFit.fitWidth,
                      ),
                    ),
                    child: passwordFooterBar,
                  ),
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.center, 
                    mainAxisAlignment: MainAxisAlignment.start,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Container(
                        height: MediaQuery.of(context).size.height*0.06,
                        width: MediaQuery.of(context).size.width,
                        alignment: Alignment.center,
                        decoration: Constants.backgroundDecoration,
                        child: TabBar(
                          tabs: tabList,
                          isScrollable: true,
                          dragStartBehavior: DragStartBehavior.down,
                          tabAlignment: TabAlignment.center,
                          labelColor: Constants.lightText,
                          unselectedLabelColor: Constants.semiLightText,
                          indicatorColor: Constants.appBarColor,
                        ),
                      ),
                      Container(
                        height: MediaQuery.of(context).size.height*0.79,
                        width: MediaQuery.of(context).size.width,
                        alignment: Alignment.center,
                        decoration: Constants.backgroundDecoration,
                        child: TabBarView(
                          physics: PageScrollPhysics(),
                          children: tabList.map((Tab tab) {
                            return FutureBuilder(
                              future: this.pFile.getPasswordsByCategory(tab.text.toString()), 
                              builder: (context, pwdSnap) {
                                if(pwdSnap.hasData && pwdSnap.data != null){
                                  return ListView.builder(
                                    padding: const EdgeInsets.all(10),
                                    itemCount: pwdSnap.data!.length,
                                    itemBuilder: (
                                      BuildContext context,
                                      int index,
                                    ) {
                                      return Card(
                                        elevation: 6,
                                        color: Constants.cardColor,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.max,
                                          children: <Widget>[
                                            ListTile(
                                              leading: const Icon(Icons.vpn_key_outlined),
                                              title: Text(pwdSnap.data![index]['title']),
                                              subtitle: Text('${pwdSnap.data![index]['site']} | ${pwdSnap.data![index]['username']}'),
                                              textColor: Constants.lightText,
                                              iconColor: Constants.lightText,
                                            ),
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.end,
                                              children: [
                                                Spacer(flex: 1,),
                                                Expanded(flex: 3,child: TextButton(
                                                  child: const Text('Copy Password', style: TextStyle(color: Constants.lightText)),
                                                  onPressed: () async {
                                                    keyTitanPass thisPass = keyTitanPass(
                                                      title: pwdSnap.data![index]['title'], 
                                                      site: pwdSnap.data![index]['site'], 
                                                      category: pwdSnap.data![index]['category'], 
                                                      username: pwdSnap.data![index]['username'],
                                                      password: pwdSnap.data![index]['password']
                                                    );
                                                    await Clipboard.setData(ClipboardData(text: thisPass.password));
                                                  },
                                                )),      
                                                Spacer(flex: 2,),                                                                             
                                                Expanded(flex: 2,child: TextButton(
                                                  child: const Text('EDIT', style: TextStyle(color: Constants.lightText),),
                                                  onPressed: () {
                                                    keyTitanPass editing = keyTitanPass(
                                                      id: pwdSnap.data![index]['id'],
                                                      title: pwdSnap.data![index]['title'], 
                                                      site: pwdSnap.data![index]['site'], 
                                                      category: pwdSnap.data![index]['category'], 
                                                      username: pwdSnap.data![index]['username'],
                                                      password: pwdSnap.data![index]['password']
                                                    );
                                                    idCon.text = editing.id.toString();
                                                    titleCon.text = editing.title;
                                                    siteCon.text = editing.site;
                                                    catCon.text = editing.category;
                                                    userCon.text = editing.username;
                                                    passCon.text = editing.password;
                                                    passwordDialog(edit: true);
                                                  },
                                                )),
                                                //const SizedBox(width: 25),
                                                Expanded(flex: 2,child: TextButton(
                                                  onPressed: (){
                                                    deletePasswordDialog(pwdSnap.data![index]['title'], pwdSnap.data![index]['id']);
                                                  }, 
                                                  child: const Text('DELETE', style: TextStyle(color: Constants.lightText)),
                                                ))
                                              ],
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                }
                                else { return Text('No Password Data'); }
                              },
                            );
                          }).toList(),
                        )
                      )
                    ]
                  )
                ),
              //)
            );
          }
          else {
            returned = Scaffold( 
              key: _refreshKey,
              appBar: genTitanAppBar(widget.title),
              backgroundColor: Constants.backColor,
              bottomNavigationBar: Container(
                height: MediaQuery.of(context).size.height*0.078,
                width: MediaQuery.of(context).size.width,
                alignment: Alignment.center,
                decoration: Constants.backgroundDecoration,
                child: passwordFooterBar,
              ),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.center, 
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Container(
                    height: MediaQuery.of(context).size.height*0.85,
                    width: MediaQuery.of(context).size.width,
                    alignment: Alignment.center,
                    decoration: Constants.backgroundDecoration,
                    child: Center(
                      child: Text('No passwords exist yet', style: TextStyle(color: Constants.lightText, fontSize: 20,),),
                    ),
                  )
                ],
              )
            );
            return returned;
          }
        }
      }
    );
  }
}


class DefaultTabControllerListener extends StatefulWidget {
  const DefaultTabControllerListener({
    required this.onTabChanged,
    required this.child,
    super.key,
  });

  final ValueChanged<int> onTabChanged;
  final Widget child;

  @override
  State<DefaultTabControllerListener> createState() =>
      _DefaultTabControllerListenerState();
}

class _DefaultTabControllerListenerState
    extends State<DefaultTabControllerListener> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final TabController? defaultTabController = DefaultTabController.maybeOf(
      context,
    );

    assert(() {
      if (defaultTabController == null) {
        throw FlutterError(
          'No DefaultTabController for ${widget.runtimeType}.\n'
          'Error within KeyTitan types',
        );
      }
      return true;
    }());

    if (defaultTabController != _controller) {
      _controller?.removeListener(_listener);
      _controller = defaultTabController;
      _controller?.addListener(_listener);
    }
  }

  void _listener() {
    final TabController? controller = _controller;
    if (controller == null || controller.indexIsChanging) {
      return;
    }
    widget.onTabChanged(controller.index);
  }

  @override
  void dispose() {
    _controller?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}