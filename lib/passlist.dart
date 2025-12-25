import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'globals.dart';
import 'passwords.dart';

class KeyTitanList extends StatefulWidget {
  const KeyTitanList({Key? key, required this.title, required this.navigatorKey})
      : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanList> createState() => _KeyTitanListState();
}

class _KeyTitanListState extends State<KeyTitanList> {
  final headCon = TextEditingController();
  final idCon = TextEditingController();
  final titleCon = TextEditingController();
  final siteCon = TextEditingController();
  final catCon = TextEditingController();
  final userCon = TextEditingController();
  final passCon = TextEditingController();
  final complexityCon = TextEditingController();

  final ValueNotifier<int> _refreshTrigger = ValueNotifier<int>(0);
  passFile? pFile;
  bool _initialized = false;

  @override
  void dispose() {
    headCon.dispose();
    idCon.dispose();
    titleCon.dispose();
    siteCon.dispose();
    catCon.dispose();
    userCon.dispose();
    passCon.dispose();
    complexityCon.dispose();
    _refreshTrigger.dispose();
    super.dispose();
  }

@override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final args = ModalRoute.of(context)!.settings.arguments;
      
      // Change the type check from Map to passFile
      if (args != null && args is passFile) {
        pFile = args;
        // Since pFile is already decrypted in open.dart, 
        // we just need to trigger a refresh to show the data.
        _triggerRefresh(); 
      }
      
      _initialized = true;
    }
  }

  String? stringValidator(String? value, String field) {
    if (value == null || value == '') {
      return 'Please enter a valid $field';
    }
    return null;
  }

  void createPassword() async {

    await pFile!.savePassword(
      keyTitanPass(
        id: -1,//int.parse(idCon.text),
        title: titleCon.text,
        site: siteCon.text,
        category: catCon.text,
        username: userCon.text,
        displayPassword: passCon.text
      )
    );

    _triggerRefresh();
    // pop the dialog box
    Navigator.of(context, rootNavigator: true).pop();
  }

  void updatePassword() async {

    await pFile!.savePassword(
      keyTitanPass(
        id: int.parse(idCon.text),
        title: titleCon.text,
        site: siteCon.text,
        category: catCon.text,
        username: userCon.text,
        displayPassword: passCon.text
      )
    );

    _triggerRefresh();
    // pop the dialog box
    Navigator.of(context, rootNavigator: true).pop();
    //pop the (unrefreshed) screen
    //Navigator.of(context, rootNavigator: true).pop();
    //push new refreshed screen
    //widget.navigatorKey.currentState!.pushNamed(KeyTitan.passList, arguments: pFile);
  }

  void _verifyPassFile() async {
    final file = File(pFile!.fileName);
    if (await file.exists()) {
      if (pFile!.isEncrypted) {
        bool success = await pFile!.attemptDecrypt();
        if (success) _triggerRefresh();
      }
    } else {
      pFile!.newSQLFile();
    }
    if (mounted) {
        setState(() {
          // This empty setState tells Flutter that pFile is now 
          // initialized and it's time to stop showing the spinner.
        });
    }
  }

  void _triggerRefresh() => _refreshTrigger.value++;

  // --- Logic Methods ---

  void saveEntry({bool isUpdate = false}) async {
    await pFile!.savePassword(keyTitanPass(
        id: int.tryParse(idCon.text) ?? -1,
        title: titleCon.text,
        site: siteCon.text,
        category: catCon.text,
        username: userCon.text,
        displayPassword: passCon.text)); // Map UI text to displayPassword
    _triggerRefresh();
    Navigator.of(context, rootNavigator: true).pop();
  }

  void deletePassword(int id) async {
    await pFile!.deletePassword(id);
    _triggerRefresh();
    Navigator.of(context, rootNavigator: true).pop(); 
  }

  Future<void> saveAndClose() async {
    try {
      await pFile!.attemptEncrypt();
      await pFile!.dispose(); // Delete temp sqlite file
    } catch (e) {
      debugPrint(e.toString());
    }
    Navigator.of(context).pop();
  }

  void closeWithoutSaving() {
    Clipboard.setData(const ClipboardData(text: ''));
    pFile!.dispose();
    Navigator.of(context).pop();
  }

  // --- UI Dialogs ---

  void deletePasswordDialog(String title, int id) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Are you sure you want to delete $title?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => deletePassword(id),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
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
    int _passLength = Constants.defaultPassLength;
    List<DropdownMenuEntry> menuList = [];
    menuList.add(DropdownMenuEntry(value: 0, label: ''));
    List categories = await pFile!.getCategories();
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
        backgroundColor: Constants.dialogColor,
        title: TextFormField(controller: headCon, enabled: false, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Constants.lightText),),
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
                        value: _passLength.toDouble(), 
                        label: 'Password Length: ${_passLength.toInt()}',
                        onChanged: (double value) { setState(() {
                          _passLength = value.toInt(); 
                          passCon.text = keyTitanPass.genPassword(Complexity.getComplexity(complexityCon.text), _passLength.toInt());
                        });},
                        min: Constants.minPassLength.toDouble(),
                        max: Constants.maxPassLength.toDouble(),
                        divisions: (Constants.maxPassLength-Constants.minPassLength).toInt(),
                        thumbColor: Colors.white,
                        activeColor: Constants.lightText,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueGrey,
                          foregroundColor: Constants.lightText,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        ),
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
    if (pFile == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return ValueListenableBuilder(
      valueListenable: _refreshTrigger,
      builder: (context, _, __) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: pFile!.getCategories(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            final categories = snapshot.data ?? [];
            if (categories.isEmpty) {
              return _buildEmptyState();
            }

            return DefaultTabController(
              length: categories.length,
              child: Scaffold(
                appBar: AppBar(
                  leading: Image.asset( 
                    ('assets/keytitan_nobkg.png'),
                    fit: BoxFit.contain,
                    alignment: Alignment.centerRight, 
                  ),
                  title: Text(
                    "Manage Passwords", 
                    style: TextStyle(
                      fontSize: Constants.titleTextSize.toDouble(),
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.2,
                    ),
                  ),
                  centerTitle: true,
                  elevation: 4,
                  bottom: TabBar(
                    isScrollable: true,
                    tabs: categories.map((c) => Tab(text: c['category'])).toList(),
                    unselectedLabelColor: Constants.lightText,
                    labelColor: Colors.white,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 15.0, vertical: 7.0),
                    tabAlignment: TabAlignment.center,
                    
                  ),
                ),
                bottomNavigationBar: _buildBottomActionNav(),
                body: TabBarView(
                  children: categories.map((cat) {
                    return _CategoryListView(
                      category: cat['category'],
                      pFile: pFile!,
                      masterPassword: pFile!.password, // Pass seed for decryption
                      onEdit: (data, decryptedPass) {
                        idCon.text = data['id'].toString();
                        titleCon.text = data['title'];
                        siteCon.text = data['site'] ?? '';
                        catCon.text = cat['category'];
                        userCon.text = data['username'] ?? '';
                        passCon.text = decryptedPass;
                        passwordDialog(edit: true);
                      },
                      onDelete: (title, id) => deletePasswordDialog(title, id),
                    );
                  }).toList(),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomActionNav() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.add), 
            color: Colors.green,
            tooltip: 'Add New Password',
            onPressed: () => passwordDialog(),
            iconSize: Constants.footerButtonSize,
          ),
          IconButton(
            icon: const Icon(Icons.save), 
            color: Colors.blueAccent,
            tooltip: 'Save & Close',
            onPressed: saveAndClose,
            iconSize: Constants.footerButtonSize,
          ),
          IconButton(
            icon: const Icon(Icons.logout), 
            color: Colors.redAccent,
            tooltip: 'Close',
            onPressed: closeWithoutSaving,
            iconSize: Constants.footerButtonSize,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      bottomNavigationBar: _buildBottomActionNav(),
      body: Container(
        decoration: Constants.backgroundDecoration,
        child: Center(
          child: const Text('Add Your First Password!\n Click the + button below',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w300)
          ),
        ),
      ),
    );
  }
}

class _CategoryListView extends StatelessWidget {
  final String category;
  final passFile pFile;
  final String masterPassword;
  final Function(Map<String, dynamic>, String) onEdit;
  final Function(String, int) onDelete;

  const _CategoryListView({
    required this.category,
    required this.pFile,
    required this.masterPassword,
    required this.onEdit,
    required this.onDelete,
  });

  Future<void> _launchInBrowser(String urlString) async {
    if (!urlString.startsWith('https://') && !urlString.startsWith('http://')) {
      urlString = 'https://$urlString';
    }
    final Uri url = Uri.parse(urlString);

    if (url.host.isEmpty || !url.host.contains('.')) {
      return;
    }

    if (await canLaunchUrl(url)) {
      await launchUrl(
        url,
        // This line ensures it opens in the external browser
        mode: LaunchMode.externalApplication,
      );
    } else {
      throw Exception('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: pFile.getPasswordsByCategory(category),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final passwords = snapshot.data!;
        
        return Container(
        width: double.infinity,
        decoration: Constants.backgroundDecoration,
        padding: const EdgeInsets.all(24.0),
        child: ListView.builder(
          itemCount: passwords.length,
          itemBuilder: (context, index) {
            final item = passwords[index];
            // Decrypt the password for the UI
            final decrypted = keyTitanPass.hdecrypt(masterPassword, item['password']);

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: ListTile(
                title: Text(item['title']),
                subtitle: Text((item['username'] ?? '')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Open Site',
                      icon: Icon(
                        Icons.link, 
                        color: (item['site'] == null || item['site'].toString().isEmpty) 
                              ? Colors.grey 
                              : Colors.blue
                      ),
                      onPressed: (item['site'] == null || item['site'].toString().isEmpty)
                          ? null // Disable the button if no site exists
                          : () => _launchInBrowser(item['site'].toString()),
                    ),
                    const SizedBox(width: Constants.cardIconSpacing), // spacing
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy Password',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: decrypted));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Password copied to clipboard'))
                        );
                      },
                    ),
                    const SizedBox(width: Constants.cardIconSpacing), // spacing
                    IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Edit Entry',
                      color: Colors.orangeAccent,
                      onPressed: () => onEdit(item, decrypted),
                    ),
                    const SizedBox(width: Constants.cardIconSpacing), // spacing
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      tooltip: 'Delete Entry',
                      onPressed: () => onDelete(item['title'], item['id']),
                    ),
                  ],
                ),
              ),
            );
          },
        )
        );
      },
    );
  }
}
