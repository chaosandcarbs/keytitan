import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'passwords.dart';
import 'globals.dart';

class KeyTitanNew extends StatefulWidget {
  const KeyTitanNew({Key? key, required this.title, required this.navigatorKey})
      : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanNew> createState() => _KeyTitanNewState();
}

class _KeyTitanNewState extends State<KeyTitanNew> {
  final _formKey = GlobalKey<FormState>();
  
  // Controllers for form fields
  final _fileNameController = TextEditingController();
  final _filePathController = TextEditingController();
  final _passController = TextEditingController();
  final _verifyController = TextEditingController();

  @override
  void dispose() {
    _fileNameController.dispose();
    _filePathController.dispose();
    _passController.dispose();
    _verifyController.dispose();
    super.dispose();
  }

  /// Handles the directory selection via FilePicker
  Future<void> _pickDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      initialDirectory: docsDir.path,
    );

    if (selectedDirectory != null) {
      setState(() {
        _filePathController.text = selectedDirectory;
      });
    }
  }

  /// Logic to finalize the file creation and navigate
  void _handleCreateFile() {
    if (_formKey.currentState!.validate()) {
      final String fileName = _fileNameController.text.trim();
      final String path = _filePathController.text;
      final String pass = _passController.text;

      // Construct full path and ensure the extension is added
      final String fullPath = '$path${Platform.pathSeparator}$fileName.ktn';
      
      // Initialize the passFile object
      final passFile pFile = passFile(fullPath, pass);
      
      // Create the underlying SQL file before navigating
      pFile.newSQLFile();

      debugPrint('Created New KeyTitan File: ${pFile.fileName}');

      // Navigate to the list view, passing the new file object
      Navigator.of(context, rootNavigator: true).pop();
      Navigator.pushNamed(context, KeyTitan.passList, arguments: pFile);
    }
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
                  constraints: BoxConstraints(
                    // This forces the Column to be at least as tall as the screen
                    minHeight: constraints.maxHeight,
                  ),
                  child: IntrinsicHeight( // Helps the Column calculate space correctly
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Spacer(),
                        _buildDirectoryPicker(),
                        const SizedBox(height: 20),
                        _buildFileNameField(),
                        const SizedBox(height: 15),
                        _buildPasswordField('Password', _passController, true),
                        const SizedBox(height: 15),
                        _buildPasswordField('Verify Password', _verifyController, false),
                        const SizedBox(height: 30),
                        ElevatedButton(
                          onPressed: _handleCreateFile,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                            foregroundColor: Constants.lightText
                          ),
                          child: const Text('Create Password File'),
                        ),
                        // Now the Spacer knows how much space to fill!
                        const Spacer(), 
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back, size: 16),
                          label: const Text('Back to Home'),
                          style: TextButton.styleFrom(foregroundColor: Colors.white38),
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
        Text('Location', style: TextStyle(color: Constants.lightText, fontWeight: FontWeight.bold)),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _filePathController,
                readOnly: true,
                style: TextStyle(color: Constants.lightText),
                decoration: InputDecoration(
                  hintText: 'No directory selected',
                  hintStyle: TextStyle(color: Constants.lightText.withOpacity(0.5)),
                ),
                validator: (val) => (val == null || val.isEmpty) ? 'Please select a directory' : null,
              ),
            ),
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
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Constants.lightText)),
      ),
      validator: (val) {
        if (val == null || val.isEmpty) return 'Enter a filename';
        if (val.contains(RegExp(r'[<>:"/\\|?*]'))) return 'Invalid characters in name';
        return null;
      },
    );
  }

  Widget _buildPasswordField(String label, TextEditingController controller, bool isPrimary) {
    return TextFormField(
      controller: controller,
      obscureText: true,
      style: TextStyle(color: Constants.lightText),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Constants.lightText),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Constants.lightText)),
      ),
      validator: (val) {
        if (val == null || val.isEmpty) return 'Password required';
        if (!isPrimary && val != _passController.text) return 'Passwords do not match';
        return null;
      },
    );
  }
}