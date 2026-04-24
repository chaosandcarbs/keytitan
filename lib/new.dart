import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'passwords.dart';
import 'globals.dart';

class KeyTitanNew extends StatefulWidget {
  const KeyTitanNew(
      {super.key, required this.title, required this.navigatorKey});

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanNew> createState() => _KeyTitanNewState();
}

class _KeyTitanNewState extends State<KeyTitanNew> {
  final _formKey = GlobalKey<FormState>();
  final _fileNameController = TextEditingController();
  final _filePathController = TextEditingController();
  final _passController = TextEditingController();
  final _verifyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pre-populate the path field with app-private storage on all platforms.
    // On Android this is the only directory we can reliably write to. On
    // desktop it's a sensible default that the user can still change.
    _setDefaultDirectory();
  }

  Future<void> _setDefaultDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    if (mounted) setState(() => _filePathController.text = appDir.path);
  }

  @override
  void dispose() {
    _fileNameController.dispose();
    _filePathController.dispose();
    _passController.dispose();
    _verifyController.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final selected = await FilePicker.platform.getDirectoryPath(
      initialDirectory: appDir.path,
    );
    if (selected != null) {
      setState(() => _filePathController.text = selected);
    }
  }

  Future<void> _handleCreateFile() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _fileNameController.text.trim();
    final dir = _filePathController.text;
    final pass = _passController.text;

    _passController.clear();
    _verifyController.clear();

    // On Android, Platform.pathSeparator is '/' — same as p.join uses.
    final fullPath = p.join(dir, '$name.ktn');
    final pFile = passFile(fullPath, pass);

    await pFile.newSQLFile();

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    Navigator.pushNamed(context, KeyTitan.passList, arguments: pFile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),
      backgroundColor: Constants.backColor,
      body: Container(
        decoration: Constants.backgroundDecoration,
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Form(
          key: _formKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Spacer(),
                        _buildDirectoryPicker(),
                        const SizedBox(height: 20),
                        _buildFileNameField(),
                        const SizedBox(height: 15),
                        _buildPasswordField('Password', _passController,
                            isPrimary: true),
                        const SizedBox(height: 15),
                        _buildPasswordField(
                            'Verify Password', _verifyController,
                            isPrimary: false),
                        const SizedBox(height: 30),
                        ElevatedButton(
                          onPressed: _handleCreateFile,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 40, vertical: 15),
                            foregroundColor: Constants.lightText,
                          ),
                          child: const Text('Create Password File'),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back, size: 16),
                          label: const Text('Back to Home'),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white38),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDirectoryPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Location',
          style: TextStyle(
              color: Constants.lightText, fontWeight: FontWeight.bold),
        ),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _filePathController,
                readOnly: true,
                style: TextStyle(color: Constants.lightText),
                decoration: InputDecoration(
                  hintText: 'Loading default directory…',
                  hintStyle: TextStyle(
                      color: Constants.lightText.withValues(alpha: 0.5)),
                ),
                validator: (v) => (v == null || v.isEmpty)
                    ? 'Please select a directory'
                    : null,
              ),
            ),
            // Hide the directory picker on Android — the app-private dir is
            // the only sensible location and the picker can't grant persistent
            // access to anything else.
            if (!Constants.isMobile)
              IconButton(
                icon: Icon(Icons.folder_open, color: Constants.lightText),
                onPressed: _pickDirectory,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildFileNameField() {
    return TextFormField(
      controller: _fileNameController,
      style: TextStyle(color: Constants.lightText),
      decoration: InputDecoration(
        labelText: 'File Name',
        labelStyle: TextStyle(color: Constants.lightText),
        suffixText: '.ktn',
        suffixStyle: TextStyle(color: Constants.lightText),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: Constants.lightText),
        ),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Enter a filename';
        if (v.contains(RegExp(r'[<>:"/\\|?*]'))) {
          return 'Filename contains invalid characters';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField(
    String label,
    TextEditingController controller, {
    required bool isPrimary,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: true,
      style: TextStyle(color: Constants.lightText),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Constants.lightText),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: Constants.lightText),
        ),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Password required';
        if (!isPrimary && v != _passController.text) {
          return 'Passwords do not match';
        }
        return null;
      },
    );
  }
}
